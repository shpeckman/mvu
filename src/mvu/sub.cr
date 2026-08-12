# src/mvu/sub.cr
require "./sub_id"
require "./msg"

module MVU
  struct Sub
    NONE   = [] of Sub
    NO_IDS = [] of SubId

    getter id   : SubId
    getter task : Proc(Proc(Msg, Nil), Channel(Nil), Nil)

    def initialize(@id : SubId, &@task : Proc(Msg, Nil), Channel(Nil) ->)
    end

    def map(tag : Symbol, &mapper : Msg -> Msg) : Sub
      Sub.new(PrefixedId.new(tag, @id)) do |dispatch, cancel|
        mapped_dispatch = ->(msg : Msg) { dispatch.call(mapper.call(msg)) }
        @task.call(mapped_dispatch, cancel)
      end
    end

    class Handle
      getter cancel       : Channel(Nil)
      property generation : UInt32

      def initialize(@cancel : Channel(Nil), @generation : UInt32)
      end
    end
  end
end
