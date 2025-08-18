defmodule EmqxRealtimeApiTest do
  use ExUnit.Case
  doctest EmqxRealtimeApi

  test "greets the world" do
    assert EmqxRealtimeApi.hello() == :world
  end
end
