defmodule Mom.RemoteLoggerHandlerTest do
  use ExUnit.Case

  alias Mom.RemoteLoggerHandler

  test "filters logs below min level" do
    {:ok, state} = RemoteLoggerHandler.init(%{mom_pid: self(), min_level: :error})

    {:ok, state} = RemoteLoggerHandler.log(%{level: :info}, state)
    refute_receive {:mom_log, _}

    {:ok, _state} = RemoteLoggerHandler.log(%{level: :error}, state)
    assert_receive {:mom_log, %{level: :error}}
  end
end
