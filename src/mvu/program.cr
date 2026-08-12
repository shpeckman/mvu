# src/mvu/program.cr
require "./msg"
require "./render"
require "./sub_id"
require "./sub"
require "./cmd"
require "./middleware"

class MVU::Program(M)
  CAPACITY = 1024

  @queue         : Channel(Msg)
  @inbox         : Deque(Msg)
  @active_subs   : Hash(SubId, Sub::Handle)
  @generation    : UInt32
  @dispatch_proc : Proc(Msg, Nil)
  @update_fn     : Proc(M, Msg, {M, Cmd})
  @render        : Render
  getter model   : M

  def initialize(
    initial_model : M,
    initial_cmd : Cmd = Cmd.none,
    middlewares : Array(Middleware(M)) = [] of Middleware(M),
    render : Render = Render::EveryMessage,
  )
    @queue         = Channel(Msg).new(CAPACITY)
    @inbox         = Deque(Msg).new
    @active_subs   = Hash(SubId, Sub::Handle).new
    @generation    = 0_u32
    @model         = initial_model
    @render        = render
    @dispatch_proc = ->(msg : Msg) { dispatch(msg) }

    chain = ->(m : M, msg : Msg) { m.update(msg) }

    middlewares.reverse_each do |mw|
      next_fn    = chain
      current_mw = mw
      chain      = ->(m : M, msg : Msg) { current_mw.call(m, msg, next_fn) }
    end

    @update_fn = chain

    run_cmd(initial_cmd)
    reconcile
  end

  def dispatch(msg : Msg) : Nil
    @queue.send(msg)
  rescue Channel::ClosedError
  end

  def dispatch?(msg : Msg) : Bool
    select
    when @queue.send(msg)
      true
    else
      false
    end
  rescue Channel::ClosedError
    false
  end

  def stop : Nil
    @queue.close
  end

  def stopped? : Bool
    @queue.closed?
  end

  def run(&block : M ->) : Nil
    block.call(@model)

    unless @inbox.empty?
      pump(block)
      reconcile
      block.call(@model) if @render.coalesced?
    end

    while msg = @queue.receive?
      process(msg, block)
      drain(block)
      reconcile
      block.call(@model) if @render.coalesced?
    end

    shutdown
  end

  private def drain(render : Proc(M, Nil)) : Nil
    loop do
      select
      when queued = @queue.receive?
        break unless queued

        process(queued, render)
      else
        break
      end
    end
  end

  private def process(msg : Msg, render : Proc(M, Nil)) : Nil
    deliver(msg, render)
    pump(render)
  end

  private def pump(render : Proc(M, Nil)) : Nil
    while msg = @inbox.shift?
      deliver(msg, render)
    end
  end

  private def deliver(msg : Msg, render : Proc(M, Nil)) : Nil
    @model, cmd = @update_fn.call(@model, msg)

    run_cmd(cmd)
    render.call(@model) if @render.every_message?
  end

  private def shutdown : Nil
    @active_subs.each_value { |handle| handle.cancel.close }
    @active_subs.clear
    @inbox.clear
  end

  private def run_cmd(cmd : Cmd) : Nil
    tasks = cmd.tasks

    return if tasks.empty?

    tasks.each do |task|
      run = task.run

      case task.mode
      in .sync?
        msg = run.call
        @inbox << msg if msg
      in .async?
        spawn do
          produced = run.call
          dispatch(produced) if produced
        end
      end
    end
  end

  private def reconcile : Nil
    ids = @model.subscription_ids

    return if ids.empty? && @active_subs.empty?

    generation  = @generation &+ 1
    @generation = generation
    active      = @active_subs.size
    matched     = 0

    ids.each do |id|
      if handle = @active_subs[id]?
        matched &+= 1 unless handle.generation == generation
        handle.generation = generation
        next
      end

      sub    = @model.subscription(id)
      cancel = Channel(Nil).new
      task   = sub.task

      @active_subs[id] = Sub::Handle.new(cancel, generation)

      spawn do
        task.call(@dispatch_proc, cancel)
      end
    end

    return if matched == active

    @active_subs.reject! do |_, handle|
      next false if handle.generation == generation

      handle.cancel.close
      true
    end
  end
end
