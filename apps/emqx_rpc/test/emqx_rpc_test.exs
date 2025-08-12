defmodule EmqxRpcTest do
  use ExUnit.Case
  doctest EmqxRpc

  test "greets the world" do
    assert EmqxRpc.hello() == :world
  end
end
