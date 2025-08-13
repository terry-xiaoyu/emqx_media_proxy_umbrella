defmodule AliRealtimeASRTest do
  use ExUnit.Case

  alias EmqxMediaRtp.AliRealtimeASR
  doctest EmqxMediaRtp

  test "test merge_asr_results" do
    assert AliRealtimeASR.merge_asr_results([], 0, []) == {[], 0}
    assert AliRealtimeASR.merge_asr_results([], 0, [%{"sentence" => %{"text" => "Hello", "begin_time" => 170}}]) == {["Hello"], 170}
    assert AliRealtimeASR.merge_asr_results(["Hello"], 170, []) == {["Hello"], 170}
    assert AliRealtimeASR.merge_asr_results(["Hello"], 170, [
      %{"sentence" => %{"text" => "Hello John", "begin_time" => 170}}]) == {["Hello John"], 170}
    assert AliRealtimeASR.merge_asr_results(["Hello"], 170, [
      %{"sentence" => %{"text" => "Hello John", "begin_time" => 170}},
      %{"sentence" => %{"text" => "Hello John, How are", "begin_time" => 170}},
    ]) == {["Hello John, How are"], 170}
    assert AliRealtimeASR.merge_asr_results(["Hello"], 170, [
      %{"sentence" => %{"text" => "Hello John", "begin_time" => 170}},
      %{"sentence" => %{"text" => "Hello John, How are", "begin_time" => 170}},
      %{"sentence" => %{"text" => "Hello John, How are you?", "begin_time" => 170}}
    ]) == {["Hello John, How are you?"], 170}
    assert AliRealtimeASR.merge_asr_results(["Hello John, How are you?"], 170, [
      %{"sentence" => %{"text" => "I am", "begin_time" => 180}},
      %{"sentence" => %{"text" => "I am fine", "begin_time" => 180}}
    ]) == {["Hello John, How are you?", "I am fine"], 180}
    assert AliRealtimeASR.merge_asr_results(["Hello John, How are you?", "I am fine"], 180, [
      %{"sentence" => %{"text" => "I am fine", "begin_time" => 180}},
      %{"sentence" => %{"text" => "I am fine, thank you", "begin_time" => 180}}
    ]) == {["Hello John, How are you?", "I am fine, thank you"], 180}
    assert AliRealtimeASR.merge_asr_results(["Hello John, How are you?", "I am fine"], 180, [
      %{"sentence" => %{"text" => "Okay,", "begin_time" => 200}},
      %{"sentence" => %{"text" => "I am fine too", "begin_time" => 210}}
    ]) == {["Hello John, How are you?", "I am fine", "Okay,", "I am fine too"], 210}
  end

end
