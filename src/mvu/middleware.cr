# src/mvu/middleware.cr
require "./msg"
require "./cmd"

abstract class MVU::Middleware(M)
  abstract def call(model : M, msg : Msg, next_fn : Proc(M, Msg, {M, Cmd})) : {M, Cmd}
end
