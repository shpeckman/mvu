# src/mvu/cmd.cr
require "./msg"

struct MVU::Cmd
  enum Mode : UInt8
    Sync
    Async
  end

  struct Task
    getter mode : Mode
    getter run  : Proc(Msg?)

    def initialize(@mode : Mode, @run : Proc(Msg?))
    end

    def map(&mapper : Msg -> Msg) : Task
      inner = @run

      Task.new(@mode, -> : Msg? {
        msg = inner.call
        msg ? mapper.call(msg) : nil
      })
    end
  end

  EMPTY = [] of Task
  NONE  = Cmd.new(EMPTY)

  getter tasks : Array(Task)

  def initialize(@tasks : Array(Task) = EMPTY)
  end

  def self.none : Cmd
    NONE
  end

  def self.sync(&block : -> Msg?) : Cmd
    new(Array(Task).new(1) << Task.new(Mode::Sync, block))
  end

  def self.of(&block : -> Msg?) : Cmd
    new(Array(Task).new(1) << Task.new(Mode::Async, block))
  end

  def self.batch(cmds : Array(Cmd)) : Cmd
    total = 0
    cmds.each { |cmd| total &+= cmd.tasks.size }

    return NONE if total == 0

    tasks = Array(Task).new(total)
    cmds.each { |cmd| tasks.concat(cmd.tasks) }

    new(tasks)
  end

  def empty? : Bool
    @tasks.empty?
  end

  def map(&mapper : Msg -> Msg) : Cmd
    return NONE if @tasks.empty?

    Cmd.new(@tasks.map { |task| task.map(&mapper) })
  end
end
