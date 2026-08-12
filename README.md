# MVU

A concurrency-safe Model-View-Update (The Elm Architecture) implementation for Crystal.

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  mvu:
    github: shpeckman/mvu
```

Then run `shards install`.

## Usage

A model is a struct that includes `MVU::Model` and implements `update` and
`view`. Messages are structs that include `MVU::Msg`.

```crystal
module App
  struct Increment; include MVU::Msg; end
  struct Decrement; include MVU::Msg; end

  struct Model
    include MVU::Model

    getter count : Int32

    def initialize(@count = 0)
    end

    def update(msg : MVU::Msg) : {self, MVU::Cmd}
      case msg
      when Increment then {Model.new(@count + 1), MVU::Cmd.none}
      when Decrement then {Model.new(@count - 1), MVU::Cmd.none}
      else {self, MVU::Cmd.none}
      end
    end

    def view : String
      "Count: #{@count}"
    end
  end
end

program = MVU::Program.new(App::Model.new)
program.run do |model|
  puts model.view
end
```

## DSL

`MVU.app` generates the model struct from a declarative block, removing the
getters, `initialize`, the `case msg` dispatch, the `{model, cmd}` return
contract, and the paired subscription methods. The counter above becomes:

```crystal
MVU.app Counter do
  state do
    count : Int32 = 0
  end

  message Increment
  message Decrement

  update do
    on Increment, {count: count + 1}
    on Decrement, {count: count - 1}
  end

  view do
    "Count: #{count}"
  end
end

program = MVU::Program.new(Counter.new)
program.run do |model|
  puts model.view
end
```

### state

Declares the model's fields. Each is a `name : Type` declaration with an
optional default. The block generates a getter per field, an `initialize` with
defaults, and an immutable `copy(...)` method that update handlers use to
produce a new model.

```crystal
state do
  count     : Int32  = 0
  label     : String = "idle"
  listening : Bool   = false
end
```

Fields without a default become required `initialize` arguments.

### message

Each `message` generates a struct that includes `MVU::Msg`. Trailing
`name : Type` arguments become getters and `initialize` parameters.

```crystal
message Increment           # empty marker message
message SetTo, value : Int32 # carries a payload
```

### update

`on Msg` clauses build the dispatch. A missing `else` arm is generated
automatically, so unhandled messages leave the model unchanged. There are two
handler forms.

The **state-only** form takes a named tuple whose keys are state fields. It is
merged into `copy(...)` and pairs with `MVU::Cmd.none`:

```crystal
update do
  on Increment, {count: count + 1}
  on Decrement, {count: count - 1}
end
```

The **block** form uses `state ...` to set fields and `cmd ...` to emit a
command. A block argument binds the matched message for field access:

```crystal
update do
  on SetTo do |m|
    state count: m.value
  end

  on Fetch do
    cmd MVU::Cmd.of { fetch_next }
    state label: "loading"
  end
end
```

Multiple `on` clauses for the same message are merged into a single arm.
Multiple `cmd` statements in one handler are combined with `MVU::Cmd.batch`.

### subscribe

Each `on :id, if: guard do |dispatch, cancel| ... end` clause generates an entry
in both `subscription_ids` (gated by the `if:` guard) and `subscription(id)`.
Declaring the two together makes it impossible to define one without the other.

```crystal
subscribe do
  on :timer, if: listening do |dispatch, cancel|
    until cancel.closed?
      sleep 1.second
      dispatch.call(Tick.new) unless cancel.closed?
    end
  end
end
```

### view

Returns the rendered `String` for the current model.

```crystal
view do
  "#{label}: #{count}"
end
```

### Full example

```crystal
MVU.app App do
  state do
    count     : Int32  = 0
    label     : String = "idle"
    listening : Bool   = false
  end

  message Increment
  message SetTo, value : Int32
  message Tick
  message Toggle

  update do
    on Increment, {count: count + 1}
    on SetTo do |m|
      state count: m.value
    end
    on Toggle, {listening: !listening}
    on Tick, {count: count + 1}
  end

  subscribe do
    on :timer, if: listening do |dispatch, cancel|
      until cancel.closed?
        sleep 1.second
        dispatch.call(Tick.new) unless cancel.closed?
      end
    end
  end

  view do
    "#{label}: #{count}"
  end
end
```

Middleware is not part of the model block; it is wired at the program layer (see
[Middleware](#middleware)).

## Commands (Cmd)

Commands represent side-effects that may yield a new Msg.

```crystal
MVU::Cmd.none             # No side-effects
MVU::Cmd.sync { ... }     # Run a blocking block that returns a Msg?
MVU::Cmd.of { ... }       # Run an async block (spawned) that returns a Msg?
MVU::Cmd.batch([...])     # Combine multiple commands
```

## Subscriptions (Sub)

Subscriptions allow listening to ongoing external events, like I/O or timers.
To use them, implement `subscription_ids` and `subscription(id)` in your model,
or declare them with the [`subscribe`](#subscribe) DSL block. The Program
automatically manages the lifecycle of subscriptions.

```crystal
def subscription_ids : Array(MVU::SubId)
  return MVU::Sub::NO_IDS unless @listening
  [:timer]
end

def subscription(id : MVU::SubId) : MVU::Sub
  case id
  when :timer
    MVU::Sub.new(id) do |dispatch, cancel|
      until cancel.closed?
        sleep 1
        dispatch.call(Tick.new) unless cancel.closed?
      end
    end
  else
    raise "Unknown sub: #{id}"
  end
end
```

## Middleware

Middleware allows hooking into the update loop (e.g., for logging or persistence).

```crystal
class Logger(M) < MVU::Middleware(M)
  def call(model : M, msg : MVU::Msg, next_fn : Proc(M, MVU::Msg, {M, MVU::Cmd})) : {M, MVU::Cmd}
    puts "Received: #{msg}"
    next_fn.call(model, msg)
  end
end

MVU::Program.new(App::Model.new, middlewares: [Logger(App::Model).new])
```