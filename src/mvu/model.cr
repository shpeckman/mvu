# src/mvu/model.cr
require "./msg"
require "./cmd"
require "./sub"
require "./sub_id"

module MVU::Model
  macro included
    macro finished
        \{% names = @type.methods.map(&.name.stringify) %}
        \{% if names.includes?("subscription_ids") && !names.includes?("subscription") %}
          \{% raise "#{@type} defines `subscription_ids` but not `subscription(id)`. Provide `def subscription(id : MVU::SubId) : MVU::Sub` returning the sub for each id." %}
        \{% end %}
        \{% if names.includes?("subscription") && !names.includes?("subscription_ids") %}
          \{% raise "#{@type} defines `subscription(id)` but not `subscription_ids`. Provide `def subscription_ids : Array(MVU::SubId)` listing the active ids." %}
        \{% end %}
      end
  end

  abstract def update(msg : Msg) : {self, Cmd}
  abstract def view : String

  def subscription_ids : Array(SubId)
    Sub::NO_IDS
  end

  def subscription(id : SubId) : Sub
    raise "#{self.class} has no subscription for #{id.inspect}"
  end
end
