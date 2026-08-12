# src/mvu.cr

# Usage
# -----
#
#   module App
#     struct Increment; include MVU::Msg; end
#     struct Decrement; include MVU::Msg; end
#
#     struct Model
#       include MVU::Model
#
#       getter count : Int32
#
#       def initialize(@count = 0)
#       end
#
#       def update(msg : MVU::Msg) : {self, MVU::Cmd}
#         case msg
#         when Increment then {Model.new(@count + 1), MVU::Cmd.none}
#         when Decrement then {Model.new(@count - 1), MVU::Cmd.none}
#         else {self, MVU::Cmd.none}
#         end
#       end
#
#       def view : String
#         "Count: #{@count}"
#       end
#     end
#   end
#
#   program = MVU::Program.new(App::Model.new)
#   program.run do |model|
#     # Render your model here
#     puts model.view
#   end
#
# DSL
# ---
#
# The macro DSL removes the boilerplate above. See `src/mvu/dsl.cr` for the
# full construct reference. A minimal counter:
#
#   MVU.app Counter do
#     state do
#       count : Int32 = 0
#     end
#
#     message Increment
#     message Decrement
#
#     update do
#       on Increment { count: count + 1 }
#       on Decrement { count: count - 1 }
#     end
#
#     view do
#       "Count: #{count}"
#     end
#   end
#
#   program = MVU::Program.new(Counter.new)
#
# Commands (Cmd)
# --------------
#
# Commands represent side-effects that may yield a new Msg.
#
#   MVU::Cmd.none             # No side-effects
#   MVU::Cmd.sync { ... }     # Run a blocking block that returns a Msg?
#   MVU::Cmd.of { ... }       # Run an async block (spawned) that returns a Msg?
#   MVU::Cmd.batch([...])     # Combine multiple commands
#
# Subscriptions (Sub)
# -------------------
#
# Subscriptions allow listening to ongoing external events, like I/O or timers.
# To use them, implement `subscription_ids` and `subscription(id)` in your model.
# The Program automatically manages the lifecycle of subscriptions.
#
#   def subscription_ids : Array(MVU::SubId)
#     return MVU::Sub::NO_IDS unless @listening
#     [:timer]
#   end
#
#   def subscription(id : MVU::SubId) : MVU::Sub
#     case id
#     when :timer
#       MVU::Sub.new(id) do |dispatch, cancel|
#         until cancel.closed?
#           sleep 1
#           dispatch.call(Tick.new) unless cancel.closed?
#         end
#       end
#     else
#       raise "Unknown sub: #{id}"
#     end
#   end
#
# Middleware
# ----------
#
# Middleware allows hooking into the update loop (e.g., for logging or persistence).
#
#   class Logger(M) < MVU::Middleware(M)
#     def call(model : M, msg : MVU::Msg, next_fn : Proc(M, MVU::Msg, {M, MVU::Cmd})) : {M, MVU::Cmd}
#       puts "Received: #{msg}"
#       next_fn.call(model, msg)
#     end
#   end
#
#   MVU::Program.new(..., middlewares: [Logger(App::Model).new])

require "set"
require "./mvu/msg"
require "./mvu/render"
require "./mvu/sub_id"
require "./mvu/sub"
require "./mvu/cmd"
require "./mvu/model"
require "./mvu/middleware"
require "./mvu/program"
require "./mvu/dsl"

module MVU
end
