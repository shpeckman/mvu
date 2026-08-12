# src/mvu/dsl.cr
require "./msg"
require "./cmd"
require "./sub"
require "./sub_id"
require "./model"

# MVU DSL
# =======
#
# `MVU.app` defines an `MVU::Model` struct from a declarative block, removing the
# mechanical boilerplate of getters, `initialize`, the `case msg` dispatch, the
# `{model, cmd}` return contract, and the paired `subscription_ids` /
# `subscription(id)` methods.
#
# Full construct reference
# ------------------------
#
#   MVU.app Counter do
#     # STATE ---------------------------------------------------------------
#     # Declares fields. Each is a `TypeDeclaration` with an optional default.
#     # Generates a getter per field, an `initialize` with defaults, and an
#     # immutable `copy(...)` copy-constructor used by state handlers.
#     state do
#       count     : Int32  = 0
#       label     : String = "idle"
#       listening : Bool   = false
#     end
#
#     # MESSAGES ------------------------------------------------------------
#     # Each `message` generates a `struct` including `MVU::Msg`. Trailing
#     # `field : Type` args become getters + initialize params.
#     message Increment
#     message Decrement
#     message SetTo, value : Int32
#     message Tick
#     message Toggle
#
#     # UPDATE --------------------------------------------------------------
#     # `on Msg` clauses build the dispatch. Three handler forms:
#     #
#     #   State-only (named-tuple): merged into `copy(...)`, Cmd.none.
#     #     on Increment, {count: count + 1}
#     #
#     #   Block form: `state ...` sets fields, `cmd ...` adds a command.
#     #   A block arg binds the matched message for field access.
#     #     on SetTo do |m|
#     #       state count: m.value
#     #     end
#     #     on Increment do
#     #       cmd MVU::Cmd.of { fetch_next }
#     #       state count: count + 1
#     #     end
#     #
#     # Multiple clauses for the same message are merged into one `when` arm.
#     update do
#       on Increment, {count: count + 1}
#       on Decrement, {count: count - 1}
#       on SetTo do |m|
#         state count: m.value
#       end
#       on Toggle, {listening: !listening}
#       on Tick, {count: count + 1}
#     end
#
#     # SUBSCRIPTIONS -------------------------------------------------------
#     # Each `on :id, if: cond do |dispatch, cancel| ... end` becomes an entry
#     # in both `subscription_ids` (gated by `if:`) and `subscription(id)`.
#     subscribe do
#       on :timer, if: listening do |dispatch, cancel|
#         until cancel.closed?
#           sleep 1.second
#           dispatch.call(Tick.new) unless cancel.closed?
#         end
#       end
#     end
#
#     # VIEW ----------------------------------------------------------------
#     view do
#       "#{label}: #{count}"
#     end
#   end
#
# Middleware lives at the program layer, not in the model block; wire it via
# `MVU::Program.new(model, middlewares: [...])`.

module MVU
  macro app(name, &block)
    struct {{name.id}}
      include ::MVU::Model

      {% body = block.body %}
      {% exprs = body.is_a?(Expressions) ? body.expressions : [body] %}

      # ---- Partition the top-level sections -----------------------------
      {% state_fields = [] of ASTNode %}
      {% messages = [] of ASTNode %}
      {% update_block = nil %}
      {% subscribe_block = nil %}
      {% view_block = nil %}

      {% for expr in exprs %}
        {% if expr.is_a?(Call) && expr.name == "state" %}
          {% if b = expr.block %}
            {% sbody = b.body %}
            {% sexprs = sbody.is_a?(Expressions) ? sbody.expressions : [sbody] %}
            {% for f in sexprs %}
              {% if f.is_a?(TypeDeclaration) %}
                {% state_fields << f %}
              {% elsif f.is_a?(Nop) %}
              {% else %}
                {% f.raise "MVU.app `state` expects `name : Type = default` declarations, got #{f.class_name}: #{f}" %}
              {% end %}
            {% end %}
          {% else %}
            {% expr.raise "MVU.app `state` requires a block: `state do ... end`" %}
          {% end %}
        {% elsif expr.is_a?(Call) && expr.name == "message" %}
          {% messages << expr %}
        {% elsif expr.is_a?(Call) && expr.name == "update" %}
          {% expr.raise "MVU.app `update` requires a block" unless expr.block %}
          {% update_block = expr.block %}
        {% elsif expr.is_a?(Call) && expr.name == "subscribe" %}
          {% expr.raise "MVU.app `subscribe` requires a block" unless expr.block %}
          {% subscribe_block = expr.block %}
        {% elsif expr.is_a?(Call) && expr.name == "view" %}
          {% expr.raise "MVU.app `view` requires a block" unless expr.block %}
          {% view_block = expr.block %}
        {% elsif expr.is_a?(Nop) %}
        {% else %}
          {% expr.raise "MVU.app: unexpected `#{expr}`. Valid sections: state, message, update, subscribe, view." %}
        {% end %}
      {% end %}

      {% state_names = state_fields.map { |f| f.var.id } %}

      # ---- State: getters, initialize, immutable copy -------------------
      {% for f in state_fields %}
        getter {{f.var.id}} : {{f.type}}
      {% end %}

      def initialize(
        {% for f in state_fields %}
          {% if f.value.is_a?(Nop) %}
            @{{f.var.id}} : {{f.type}},
          {% else %}
            @{{f.var.id}} : {{f.type}} = {{f.value}},
          {% end %}
        {% end %}
      )
      end

      def copy(
        {% for f in state_fields %}
          {{f.var.id}} : {{f.type}} = @{{f.var.id}},
        {% end %}
      ) : self
        {{name.id}}.new(
          {% for f in state_fields %}
            {{f.var.id}},
          {% end %}
        )
      end

      # ---- Messages -----------------------------------------------------
      {% for m in messages %}
        {% m.raise "MVU.app `message` needs a name: `message Increment`" if m.args.empty? %}
        {% msg_name = m.args.first %}
        {% msg_fields = m.args[1..-1] %}
        struct {{msg_name.id}}
          include ::MVU::Msg
          {% for fld in msg_fields %}
            {% unless fld.is_a?(TypeDeclaration) %}
              {% fld.raise "MVU.app `message #{msg_name}` fields must be `name : Type`, got: #{fld}" %}
            {% end %}
            getter {{fld.var.id}} : {{fld.type}}
          {% end %}
          {% unless msg_fields.empty? %}
            def initialize(
              {% for fld in msg_fields %}
                @{{fld.var.id}} : {{fld.type}},
              {% end %}
            )
            end
          {% end %}
        end
      {% end %}

      # ---- update -------------------------------------------------------
      {% if update_block %}
        {% ubody = update_block.body %}
        {% uexprs = ubody.is_a?(Expressions) ? ubody.expressions : [ubody] %}

        # Collect clauses grouped by message name, preserving order.
        {% order = [] of ASTNode %}
        {% by_msg = {} of ASTNode => ArrayLiteral(ASTNode) %}

        {% for clause in uexprs %}
          {% if clause.is_a?(Call) && clause.name == "on" %}
            {% clause.raise "MVU.app update `on` needs a message type: `on Increment, {...}`" if clause.args.empty? %}
            {% mname = clause.args.first %}
            {% key = mname.id.stringify %}
            {% unless by_msg[key] %}
              {% by_msg[key] = [] of ASTNode %}
              {% order << mname %}
            {% end %}
            {% by_msg[key] << clause %}
          {% elsif clause.is_a?(Nop) %}
          {% else %}
            {% clause.raise "MVU.app update: only `on Msg ...` clauses allowed, got: #{clause}" %}
          {% end %}
        {% end %}

        def update(msg : ::MVU::Msg) : {self, ::MVU::Cmd}
          case msg
          {% for mname in order %}
          when {{mname.id}}
            {% clauses = by_msg[mname.id.stringify] %}
            {% state_updates = {} of ASTNode => ASTNode %}
            {% state_order = [] of ASTNode %}
            {% cmds = [] of ASTNode %}
            {% binder = nil %}

            {% for clause in clauses %}
              # State-only form: `on Msg, {field: expr, ...}`
              {% if clause.args.size >= 2 && clause.args[1].is_a?(NamedTupleLiteral) %}
                {% nt = clause.args[1] %}
                {% for k, v in nt %}
                  {% unless state_names.map(&.stringify).includes?(k.id.stringify) %}
                    {% clause.raise "MVU.app update: `#{k}` is not a state field of #{name}. Known: #{state_names.map(&.stringify)}" %}
                  {% end %}
                  {% unless state_updates[k.id.stringify] %}
                    {% state_order << k.id %}
                  {% end %}
                  {% state_updates[k.id.stringify] = v %}
                {% end %}
              {% end %}

              # Block form: `on Msg do |m| state ...; cmd ... end`
              {% if b = clause.block %}
                {% if b.args.size > 0 %}
                  {% binder = b.args.first %}
                {% end %}
                {% bbody = b.body %}
                {% bexprs = bbody.is_a?(Expressions) ? bbody.expressions : [bbody] %}
                {% for stmt in bexprs %}
                  {% if stmt.is_a?(Call) && stmt.name == "state" %}
                    {% na = stmt.named_args %}
                    {% stmt.raise "MVU.app update: `state` needs field assignments: `state count: expr`" unless na %}
                    {% for a in na %}
                      {% k = a.name %}
                      {% v = a.value %}
                      {% unless state_names.map(&.stringify).includes?(k.id.stringify) %}
                        {% stmt.raise "MVU.app update: `#{k}` is not a state field of #{name}. Known: #{state_names.map(&.stringify)}" %}
                      {% end %}
                      {% unless state_updates[k.id.stringify] %}
                        {% state_order << k.id %}
                      {% end %}
                      {% state_updates[k.id.stringify] = v %}
                    {% end %}
                  {% elsif stmt.is_a?(Call) && stmt.name == "cmd" %}
                    {% stmt.raise "MVU.app update: `cmd` needs an expression" if stmt.args.empty? %}
                    {% cmds << stmt.args.first %}
                  {% elsif stmt.is_a?(Nop) %}
                  {% else %}
                    {% stmt.raise "MVU.app update: inside `on ... do` only `state ...` and `cmd ...` are allowed, got: #{stmt}" %}
                  {% end %}
                {% end %}
              {% end %}
            {% end %}

            {% if binder %}
              {{binder.id}} = msg.as({{mname.id}})
            {% end %}

            {% if state_order.empty? %}
              new_model = self
            {% else %}
              new_model = copy({% for k in state_order %}{{k.id}}: ({{state_updates[k.id.stringify]}}){% unless k == state_order.last %}, {% end %}{% end %})
            {% end %}

            {% if cmds.empty? %}
              {new_model, ::MVU::Cmd.none}
            {% elsif cmds.size == 1 %}
              {new_model, {{cmds.first}}}
            {% else %}
              {new_model, ::MVU::Cmd.batch([
                {% for c in cmds %}
                  {{c}},
                {% end %}
              ] of ::MVU::Cmd)}
            {% end %}
          {% end %}
          else
            {self, ::MVU::Cmd.none}
          end
        end
      {% end %}

      # ---- subscriptions ------------------------------------------------
      {% if subscribe_block %}
        {% sbody = subscribe_block.body %}
        {% sexprs = sbody.is_a?(Expressions) ? sbody.expressions : [sbody] %}
        {% subs = [] of ASTNode %}
        {% for s in sexprs %}
          {% if s.is_a?(Call) && s.name == "on" %}
            {% s.raise "MVU.app subscribe `on` needs an id: `on :timer, if: cond do ... end`" if s.args.empty? %}
            {% s.raise "MVU.app subscribe `on #{s.args.first}` needs a `do |dispatch, cancel| ... end` block" unless s.block %}
            {% subs << s %}
          {% elsif s.is_a?(Nop) %}
          {% else %}
            {% s.raise "MVU.app subscribe: only `on :id ... do ... end` clauses allowed, got: #{s}" %}
          {% end %}
        {% end %}

        def subscription_ids : Array(::MVU::SubId)
          {% if subs.empty? %}
            ::MVU::Sub::NO_IDS
          {% else %}
            ids = [] of ::MVU::SubId
            {% for s in subs %}
              {% sid = s.args.first %}
              {% guard = nil %}
              {% if na = s.named_args %}
                {% for a in na %}
                  {% guard = a.value if a.name.id.stringify == "if" %}
                {% end %}
              {% end %}
              {% if guard %}
                ids << {{sid}} if {{guard}}
              {% else %}
                ids << {{sid}}
              {% end %}
            {% end %}
            ids
          {% end %}
        end

        def subscription(id : ::MVU::SubId) : ::MVU::Sub
          case id
          {% for s in subs %}
            {% sid = s.args.first %}
            {% blk = s.block %}
            when {{sid}}
              ::MVU::Sub.new({{sid}}) do |{{blk.args.splat}}|
                {{blk.body}}
              end
          {% end %}
          else
            raise "#{self.class} has no subscription for #{id.inspect}"
          end
        end
      {% end %}

      # ---- view ---------------------------------------------------------
      {% if view_block %}
        def view : String
          {{view_block.body}}
        end
      {% end %}
    end
  end
end
