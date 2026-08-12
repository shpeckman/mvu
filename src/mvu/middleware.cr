# src/mvu/middleware.cr
require "./msg"
require "./cmd"

module MVU
  abstract class Middleware(M)
    abstract def call(model : M, msg : Msg, next_fn : Proc(M, Msg, {M, Cmd})) : {M, Cmd}
  end
end
