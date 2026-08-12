# spec/compile_errors_spec.cr
require "./spec_helper"

private def compile_error(source : String) : String
  spec_dir = File.expand_path("..", __FILE__)
  path     = File.join(spec_dir, "__ce_case_#{Random.rand(UInt32)}.cr")
  File.write(path, %(require "../src/mvu"\n#{source}\n))
  output = IO::Memory.new
  status = Process.run(
    "crystal",
    ["build", "--no-codegen", path],
    output: output,
    error: output,
  )
  raise "expected compile error but compilation succeeded:\n#{source}" if status.success?
  output.to_s
ensure
  File.delete(path) if path && File.exists?(path)
end

describe "MVU.app DSL compile-time errors" do
  it "rejects an unknown state field in a handler" do
    msg = compile_error(<<-'CR')
      MVU.app CE1 do
        state do
          count : Int32 = 0
        end
        message Set
        update do
          on Set, {kount: 1}
        end
        view { "#{count}" }
      end
      CR
    msg.should contain("is not a state field")
  end

  it "rejects a malformed message field" do
    msg = compile_error(<<-'CR')
      MVU.app CE2 do
        state do
          count : Int32 = 0
        end
        message Set, 123
        update do
          on Set, {count: 1}
        end
        view { "#{count}" }
      end
      CR
    msg.should contain("fields must be")
  end

  it "rejects a non-state/cmd statement inside a block handler" do
    msg = compile_error(<<-'CR')
      MVU.app CE3 do
        state do
          count : Int32 = 0
        end
        message Set
        update do
          on Set do
            puts "nope"
          end
        end
        view { "#{count}" }
      end
      CR
    msg.should contain("only `state ...` and `cmd ...`")
  end

  it "rejects an unexpected top-level section" do
    msg = compile_error(<<-'CR')
      MVU.app CE4 do
        state do
          count : Int32 = 0
        end
        surprise 1
        view { "#{count}" }
      end
      CR
    msg.should contain("unexpected")
  end
end
