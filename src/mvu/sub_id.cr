# src/mvu/sub_id.cr
module MVU
  class PrefixedId
    getter tag   : Symbol
    getter inner : SubId

    def initialize(@tag : Symbol, @inner : SubId)
    end

    def_equals_and_hash @tag, @inner

    def to_s(io : IO) : Nil
      io << @tag << ':' << @inner
    end
  end

  alias SubId = Symbol | Int32 | Int64 | PrefixedId
end
