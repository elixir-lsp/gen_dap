defmodule GenDAP.Support.Buffer do
  def loop(args, pid, buffer) do
    case GenDAP.Communication.TCP.read(args, buffer) do
      :eof ->
        :eof

      {:ok, body, buffer} ->
        body
        |> Jason.decode!()
        |> (fn b ->
              send(pid, {:packet, b})
              b
            end).()
        |> Jason.encode_to_iodata!()
        |> GenDAP.Communication.TCP.write(args)

        loop(args, pid, buffer)
    end
  end
end

defmodule GenDAP.Communication.TCPTest do
  use ExUnit.Case, async: true

  # this includes a char that is 3 bytes in length, that is also very long so that the packet is chunked
  @string ~s|{"a":"‘","b":"#{String.duplicate("hello world! ", 5000)}"}|
  @length byte_size(@string)

  @port 9000

  @connect_opts [:binary, packet: :raw, active: false]

  test "works" do
    me = self()
    # the following match ensures that the script completes and does
    # not raise after stdin is closed.
    Task.start_link(fn ->
      {:ok, args} = GenDAP.Communication.TCP.init(port: @port)
      {:ok, args} = GenDAP.Communication.TCP.listen(args)
      send(me, {:done, args})

      assert :eof = GenDAP.Support.Buffer.loop(args, me, "")
    end)

    assert {:ok, socket} = connect()
    expected_message = "Content-Length: #{@length}\r\n\r\n#{@string}"

    assert :ok ==
             :gen_tcp.send(
               socket,
               "Whoa: Buddy\nContent-Length: #{@length}\nFoo: Bar\r\n\r\n#{@string}"
             )

    {:ok, actual} = :gen_tcp.recv(socket, byte_size(expected_message))
    assert :ok == :gen_tcp.close(socket)

    assert expected_message == actual
  end

  test "correctly reads from the socket" do
    me = self()

    {:ok, task} =
      Task.start_link(fn ->
        Process.flag(:trap_exit, true)
        {:ok, args} = GenDAP.Communication.TCP.init(port: @port)
        {:ok, args} = GenDAP.Communication.TCP.listen(args)

        assert :eof = GenDAP.Support.Buffer.loop(args, me, "")
      end)

    ref = Process.monitor(task)

    assert {:ok, socket} = connect()

    assert :ok ==
             :gen_tcp.send(
               socket,
               "Content-Length: 52\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}"
             )

    assert :ok ==
             :gen_tcp.send(
               socket,
               "Content-Length: 131\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"message\":\"[GenDAP] Processing GenDAP.Notifications.Initialized\",\"type\":4}}"
             )

    assert :ok ==
             :gen_tcp.send(
               socket,
               "Content-Length: 103\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"message\":\"[Credo] DAP Initialized!\",\"type\":4}}"
             )

    assert_receive {:packet, %{"method" => "initialized"}}

    assert_receive {:packet,
                    %{
                      "method" => "window/logMessage",
                      "params" => %{
                        "message" => "[GenDAP] Processing GenDAP.Notifications.Initialized"
                      }
                    }}

    assert_receive {:packet,
                    %{
                      "method" => "window/logMessage",
                      "params" => %{
                        "message" => "[Credo] DAP Initialized!"
                      }
                    }}

    assert :ok == :gen_tcp.close(socket)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
  end

  defp connect() do
    start_time = System.monotonic_time(:millisecond)

    connect(start_time)
  end

  defp connect(start_time) do
    now = System.monotonic_time(:millisecond)

    case :gen_tcp.connect(~c"localhost", @port, @connect_opts) do
      {:error, :econnrefused} when now - start_time > 5000 ->
        connect(start_time)

      other ->
        other
    end
  end
end
