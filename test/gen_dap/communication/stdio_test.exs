defmodule GenDAP.Communication.StdioTest do
  use ExUnit.Case, async: true

  # this includes a char that is 3 bytes in length
  @string ~s|{"a":"‘"}|
  @length byte_size(@string)

  @command "elixir --erl '-kernel standard_io_encoding latin1' -S mix run -e '
defmodule GenDAP.Support.Buffer do
  def loop do
    case GenDAP.Communication.Stdio.read([], nil) do
      :eof ->
        :eof

      {:ok, body, _} ->
        body
        |> Jason.decode!()
        |> Jason.encode_to_iodata!()
        |> GenDAP.Communication.Stdio.write([])

        loop()
    end
  end
end

defmodule Main do
  def run() do
    GenDAP.Communication.Stdio.init([])

    # the following match ensures that the script completes and does
    # not raise after stdin is closed.
    :eof = GenDAP.Support.Buffer.loop()
  end
end

Main.run()'"

  test "can read and write through stdio" do
    port = Port.open({:spawn, @command}, [:binary, env: [{~c"MIX_ENV", ~c"test"}]])

    expected_message = "Content-Length: #{@length}\r\n\r\n#{@string}"

    # send our message
    assert Port.command(
             port,
             "Whoa: Buddy\nContent-Length: #{@length}\nFoo: Bar\r\n\r\n#{@string}"
           )

    # assert the message is echoed back
    assert_receive {^port, {:data, ^expected_message}}, 2000
  end
end
