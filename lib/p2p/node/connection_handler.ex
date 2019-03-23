defmodule Elixium.Node.ConnectionHandler do
  alias Elixium.P2P.Authentication
  alias Elixium.P2P.GhostProtocol.Message
  alias Elixium.Store.Oracle
  use GenServer
  require Logger

  @moduledoc """
    Manage inbound and outbound connections
  """

  def start_link(socket, pid, peers, handler_number, bidirectional \\ false) do
    GenServer.start_link(__MODULE__, [socket, pid, peers, handler_number, bidirectional], name: :"ConnectionHandler#{handler_number}")
  end

  def init([socket, pid, peers, handler_number, bidirectional]) do
    Process.send_after(self(), :start_connection, 1000)

    {:ok,
      %{
        listen_socket: socket,
        router_pid: pid,
        available_peers: peers,
        handler_name: :"ConnectionHandler#{handler_number}",
        handler_number: handler_number,
        bidirectional: bidirectional
      }
    }
  end

  def handle_info(:start_connection, state) do
    case state.available_peers do
      :not_found ->
        Logger.warn("(Handler #{state.handler_number}): No known peers! Accepting inbound connections instead.")
        GenServer.cast(state.handler_name, :accept_inbound_connection)

      peers ->
        if state.bidirectional && length(peers) >= state.handler_number do
          {ip, port} = Enum.at(peers, state.handler_number - 1)

          GenServer.cast(state.handler_name, {:attempt_outbound_connection, {ip, port}})
        else
          GenServer.cast(state.handler_name, :accept_inbound_connection)
        end
    end

    :pg2.join(:p2p_handlers, self())

    {:noreply, state}
  end

  @doc """
    When receiving a message through TCP, send the data back to the parent
    process so it can handle it however it wants
  """
  def handle_info({:tcp, _port, data}, state) do
    messages = Message.read(data, state.session_key, state.socket)

    :inet.setopts(state.socket, active: :once)

    # Send out the messages to the parent of this process (a.k.a the pid that
    # was passed in when calling start/2)
    Enum.each(messages, fn message ->
      case message do
        %{type: "PING"} ->
          {:ok, m} = Message.build("PANG", %{}, state.session_key)
          Message.send(m, state.socket)
        %{type: "PANG"} ->
          last_ping = Process.get(:last_ping_time)
          ping = :os.system_time(:millisecond) - last_ping
          Process.put(:ping, ping)
        message ->
          send(state.router_pid, {message, self()})
      end
    end)

    {:noreply, state}
  end

  def handle_info({:tcp_closed, _}, state) do
    Logger.info("Lost connection from peer: #{state.peername}. TCP closed")
    Process.exit(self(), :normal)
  end

  def handle_info({"PING", _}, state) do
    Process.put(:last_ping_time, :os.system_time(:millisecond))

    case Message.build("PING", %{}, state.session_key) do
      {:ok, m} -> Message.send(m, state.socket)
      :error -> Logger.error("MESSAGE NOT SENT: PING")
    end

    {:noreply, state}
  end

  @doc """
    When receiving data from the parent process, send it to the network
    through TCP
  """
  def handle_info({type, data}, state) do
    case Message.build(type, data, state.session_key) do
      {:ok, m} -> Message.send(m, state.socket)
      :error -> Logger.error("MESSAGE NOT SENT: Invalid message data: expected map.")
    end

    {:noreply, state}
  end

  def handle_info(m, state) do
    Logger.warn("Received message we haven't accounted for. Skipping! Message: #{inspect(m)}")

    {:noreply, state}
  end

  def handle_cast(:accept_inbound_connection, state) do
    {:ok, socket} = :gen_tcp.accept(state.listen_socket)

    peername = get_peername(socket)

    if has_existing_connection?(socket) do
      Process.exit(self(), :normal)
    end

    # Here would be a good place to put an IP blacklisting safeguard...
    Logger.info("#{state.handler_name} Accepted potential handshake from #{peername}")

    handshake = Message.read(socket)

    shared_secret =
      case handshake do
        %{prime: _, generator: _, verifier: _, public_value: _} ->
          Authentication.inbound_auth(handshake, socket)
        _ ->
          "INVALID_AUTH"
          |> Message.build(%{})
          |> Message.send(socket)

          Process.exit(self(), :normal)
      end

    {session_key, peername} = prepare_connection_loop(socket, shared_secret, state, :inbound)

    state = Map.merge(state, %{
      socket: socket,
      session_key: session_key,
      peername: peername,
      conntype: :inbound
    })

    {:noreply, state}
  end

  def handle_cast({:attempt_outbound_connection, {ip, port}}, state) do
    Logger.info("#{state.handler_name} attempting connection to peer at host: #{ip}, port: #{port}...")

    case :gen_tcp.connect(ip, port, [:binary, active: false], 1000) do
      {:ok, socket} ->
        Logger.info("#{state.handler_name} connected to peer at host: #{ip}")

        shared_secret = Authentication.outbound_auth(socket)

        Oracle.inquire(:"Elixir.Elixium.Store.PeerOracle", {:save_known_peer, [{ip, port}]})

        {session_key, peername} = prepare_connection_loop(socket, shared_secret, state, :outbound)

        state = Map.merge(state, %{
          socket: socket,
          session_key: session_key,
          peername: peername,
          conntype: :outbound
        })

        {:noreply, state}

      {:error, reason} ->
        Logger.warn("#{state.handler_name} -- Error connecting to peer: #{reason}. Starting listener instead.")

        GenServer.cast(state.handler_name, :accept_inbound_connection)

        {:noreply, state}
    end
  end

  defp prepare_connection_loop(socket, shared_secret, state, conn_type) do
    session_key = generate_session_key(shared_secret)

    :inet.setopts(socket, active: :once)

    peername = get_peername(socket)

    Logger.info("#{state.handler_name} authenticated with peer #{peername}")

    # Set the connected flag so that the parent process knows we've connected
    # to a peer.
    Process.put(:connected, peername)
    #Initialize Ping to prevent default errors
    Process.put(:ping, 0)

    # Tell the master pid that we have a new connection
    if conn_type == :outbound do
      send(state.router_pid, {:new_outbound_connection, self()})
    else
      send(state.router_pid, {:new_inbound_connection, self()})
    end

    {session_key, peername}
  end

  defp generate_session_key(shared_secret) do
    # Truncate the key to be 32 bytes (256 bits) since AES256 won't accept anything bigger.
    # Originally, I was worried this would be a security flaw, but according to
    # https://crypto.stackexchange.com/questions/3288/is-truncating-a-hashed-private-key-with-sha-1-safe-to-use-as-the-symmetric-key-f
    # it isn't
    <<session_key::binary-size(32)>> <> _ = shared_secret

    session_key
  end

  # Returns a string containing the IP of whoever is on the other end
  # of the given socket
  @spec get_peername(reference) :: String.t()
  defp get_peername(socket) do
    {:ok, {addr, _port}} = :inet.peername(socket)

    addr
    |> :inet_parse.ntoa()
    |> to_string()
  end

  @spec has_existing_connection?(reference) :: {boolean, pid} | false
  def has_existing_connection?(socket) do
    peername = get_peername(socket)

    handler =
      :p2p_handlers
      |> :pg2.get_members()
      |> Enum.find(fn p ->
          connected =
            p
            |> Process.info()
            |> Keyword.get(:dictionary)
            |> Keyword.get(:connected)

          connected == peername
        end)

    if handler do
      {true, handler}
    else
      false
    end
  end

  def ping_peer(peer) do
    with {"PING", %{}} <- send(peer, {"PING", %{}}) do
      peer
      |> Process.info()
      |> Keyword.get(:dictionary)
      |> Keyword.get(:ping)
    end
  end
end
