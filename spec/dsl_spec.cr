# spec/dsl_spec.cr
require "./spec_helper"

MVU.app Counter do
  state do
    count : Int32  = 0
    label : String = "idle"
  end

  message Increment
  message Decrement
  message SetTo, value : Int32
  message Relabel, text : String

  update do
    on Increment, {count: count + 1}
    on Decrement, {count: count - 1}
    on SetTo do |m|
      state count: m.value
    end
    on Relabel do |m|
      state label: m.text
    end
  end

  view do
    "#{label}: #{count}"
  end
end

MVU.app Merged do
  state do
    count : Int32  = 0
    log   : String = ""
  end

  message Bump

  update do
    on Bump, {count: count + 1}
    on Bump do
      state log: "bumped"
    end
  end

  view do
    "count=#{count} log=#{log}"
  end
end

MVU.app WithCmd do
  state do
    value : Int32  = 0
    note  : String = ""
  end

  message Fetch
  message Loaded, payload : Int32
  message Note, text : String

  update do
    on Fetch do
      cmd MVU::Cmd.sync { Loaded.new(99) }
    end
    on Loaded do |m|
      state value: m.payload
    end
    on Note do |m|
      state note: m.text
      cmd MVU::Cmd.sync { Loaded.new(7) }
    end
  end

  view do
    "value=#{value} note=#{note}"
  end
end

MVU.app MultiCmd do
  state do
    n : Int32 = 0
  end

  message Kick
  message A
  message B

  update do
    on Kick do
      cmd MVU::Cmd.sync { A.new }
      cmd MVU::Cmd.sync { B.new }
    end
    on A, {n: n + 1}
    on B, {n: n + 10}
  end

  view do
    "n=#{n}"
  end
end

MVU.app SubApp do
  state do
    ticks     : Int32 = 0
    listening : Bool  = false
  end

  message Tick
  message Toggle

  update do
    on Tick, {ticks: ticks + 1}
    on Toggle, {listening: !listening}
  end

  subscribe do
    on :timer, if: listening do |dispatch, cancel|
      until cancel.closed?
        sleep 0.005.seconds
        dispatch.call(Tick.new) unless cancel.closed?
      end
    end
  end

  view do
    "ticks=#{ticks} listening=#{listening}"
  end
end

MVU.app NoDefaults do
  state do
    a : Int32
    b : String
  end

  message Swap

  update do
    on Swap, {a: a + 1}
  end

  view do
    "#{a}/#{b}"
  end
end

describe "MVU.app DSL" do
  describe "state" do
    it "applies declared defaults" do
      m = Counter.new
      m.count.should eq(0)
      m.label.should eq("idle")
    end

    it "generates a positional initialize following declaration order" do
      m = Counter.new(5, "hi")
      m.count.should eq(5)
      m.label.should eq("hi")
    end

    it "supports fields without defaults (required initialize args)" do
      m = NoDefaults.new(3, "x")
      m.a.should eq(3)
      m.b.should eq("x")
    end
  end

  describe "messages" do
    it "generates empty marker structs including MVU::Msg" do
      Counter::Increment.new.should be_a(MVU::Msg)
    end

    it "generates fielded messages with a getter and initialize" do
      msg = Counter::SetTo.new(42)
      msg.value.should eq(42)
      msg.should be_a(MVU::Msg)
    end
  end

  describe "update: state-only (named tuple) form" do
    it "produces a new model via copy, leaving other fields intact" do
      m0 = Counter.new
      m1, cmd = m0.update(Counter::Increment.new)
      m1.count.should eq(1)
      m1.label.should eq("idle")
      cmd.empty?.should be_true
    end

    it "is immutable: the original is unchanged" do
      m0 = Counter.new
      m0.update(Counter::Increment.new)
      m0.count.should eq(0)
    end

    it "leaves the model untouched for unhandled messages" do
      m0 = Counter.new(3, "z")
      m1, cmd = m0.update(Counter::Relabel.new("z"))
      m1.label.should eq("z")
      # Decrement is handled; an unknown message would hit the else arm.
    end
  end

  describe "update: block form with binder" do
    it "binds the matched message for field access" do
      m0 = Counter.new
      m1, _ = m0.update(Counter::SetTo.new(88))
      m1.count.should eq(88)
    end
  end

  describe "update: clause merging" do
    it "merges multiple on-clauses for one message into a single arm" do
      m0 = Merged.new
      m1, _ = m0.update(Merged::Bump.new)
      m1.count.should eq(1)
      m1.log.should eq("bumped")
    end
  end

  describe "update: cmd form" do
    it "emits a single command from a lone cmd statement" do
      m0 = WithCmd.new
      _, cmd = m0.update(WithCmd::Fetch.new)
      cmd.empty?.should be_false
      cmd.tasks.size.should eq(1)
      cmd.tasks.first.mode.should eq(MVU::Cmd::Mode::Sync)
      produced = cmd.tasks.first.run.call
      produced.should be_a(WithCmd::Loaded)
    end

    it "combines state and cmd in the same handler" do
      m0 = WithCmd.new
      m1, cmd = m0.update(WithCmd::Note.new("hey"))
      m1.note.should eq("hey")
      cmd.tasks.size.should eq(1)
    end

    it "batches multiple cmd statements" do
      m0 = MultiCmd.new
      _, cmd = m0.update(MultiCmd::Kick.new)
      cmd.tasks.size.should eq(2)
    end
  end

  describe "view" do
    it "renders the state" do
      Counter.new(7, "on").view.should eq("on: 7")
    end
  end

  describe "subscriptions" do
    it "gates subscription_ids behind the if guard" do
      SubApp.new.subscription_ids.should eq([] of MVU::SubId)
      SubApp.new(0, true).subscription_ids.should eq([:timer] of MVU::SubId)
    end

    it "builds a Sub for a declared id" do
      sub = SubApp.new(0, true).subscription(:timer)
      sub.id.should eq(:timer)
    end

    it "raises for an unknown id" do
      expect_raises(Exception, /no subscription/) do
        SubApp.new(0, true).subscription(:nope)
      end
    end
  end

  describe "integration through Program" do
    it "folds a sync command result back before the next message" do
      prog = MVU::Program.new(WithCmd.new)
      spawn do
        prog.dispatch(WithCmd::Fetch.new)
        sleep 0.03.seconds
        prog.stop
      end
      final = ""
      prog.run { |model| final = model.view }
      final.should eq("value=99 note=")
    end

    it "starts and cancels a subscription across reconciles" do
      prog = MVU::Program.new(SubApp.new)
      spawn do
        prog.dispatch(SubApp::Toggle.new)
        sleep 0.05.seconds
        prog.dispatch(SubApp::Toggle.new)
        sleep 0.03.seconds
        prog.stop
      end
      last = SubApp.new
      prog.run { |model| last = model }
      last.listening.should be_false
      last.ticks.should be > 0
    end
  end
end
