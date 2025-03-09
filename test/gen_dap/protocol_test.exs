defmodule GenDAP.ProtocolTest do
  use ExUnit.Case, async: true

  alias GenDAP.Requests

  describe "new/1" do
    test "decodes a terminate command" do
      initialize = %{
        "arguments" => %{
          "restart" => true
        },
        "command" => "terminate",
        "seq" => 1,
        "type" => "request"
      }

      assert {:ok,
              %GenDAP.Requests.TerminateRequest{
                arguments: %GenDAP.Structures.TerminateArguments{restart: true},
                command: "terminate",
                seq: 1,
                type: "request"
              }} = Requests.new(initialize)
    end
  end
end
