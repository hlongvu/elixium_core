defmodule Elixium.P2P.Server do
  require IEx
  alias Elixium.P2P.GhostProtocol.Parser
  alias Elixium.P2P.GhostProtocol.Message
  alias Elixium.P2P.PeerStore
  @port 31013

  # Start a server and pass the socket to a listener function
  def start do
    IO.puts "Starting server on port #{@port}."
    {:ok, listen_socket} = :gen_tcp.listen(@port, [:binary, reuseaddr: true, active: false])

    # TODO: Replace with ranch lib
    for _ <- 0..10, do: spawn(fn -> authenticate_peer(listen_socket) end)

    Process.sleep(:infinity)
  end

  defp authenticate_peer(listen_socket) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)

    peername = get_peername(socket)

    IO.puts "Accepted message from #{peername}"

    handshake =
      socket
      |> :gen_tcp.recv(0)
      |> Parser.parse

    session_key = case handshake do
      %{identifier: i, salt: s, prime: p} -> register_new_peer(handshake, socket)
      %{identifier: identifier} -> authenticate_known_peer(identifier, socket)
    end

    IO.puts "Authenticated with peer."

    server_handler(socket, session_key)
  end

  defp authenticate_known_peer(identifier, socket) do
    {salt, prime, generator, peer_verifier} = PeerStore.load_peer(identifier)

    server =
      Strap.protocol(:srp6a, prime, generator)
      |> Strap.server(peer_verifier)

    public_value =
      Strap.public_value(server)
      |> Base.encode64()

    challenge = Message.build("HANDSHAKE_CHALLENGE", %{
      salt: salt,
      prime: prime,
      generator: generator,
      public_value: public_value
    })

    :ok = :gen_tcp.send(socket, challenge)

    %{public_value: peer_public_value} =
      socket
      |> :gen_tcp.recv(0)
      |> Parser.parse

    {:ok, peer_public_value} = Base.decode64(peer_public_value)

    {:ok, shared_master_key} = Strap.session_key(server, peer_public_value)

    shared_master_key
  end

  # Handle incoming authentication messages from peers, and save to their
  # identity to the database for later
  defp register_new_peer(message, socket) do
    %{
      public_value: peer_public_value,
      generator: generator,
      prime: prime,
      verifier: peer_verifier,
      salt: salt,
      identifier: peer_identifier
    } = message

    {:ok, peer_verifier} = Base.decode64(peer_verifier)
    {:ok, peer_public_value} = Base.decode64(peer_public_value)

    server =
      Strap.protocol(:srp6a, prime, generator)
      |> Strap.server(peer_verifier)

    server_public_value =
      Strap.public_value(server)
      |> Base.encode64()

    response = Message.build("HANDSHAKE_AUTH", %{public_value: server_public_value})

    :ok = :gen_tcp.send(socket, response)

    {:ok, shared_master_key} = Strap.session_key(server, peer_public_value)

    PeerStore.register_peer({peer_identifier, salt, prime, generator, peer_verifier})

    shared_master_key
  end

  defp server_handler(socket, session_key) do
    peername = get_peername(socket)

    data =
      socket
      |> :gen_tcp.recv(0)
      |> Parser.parse

    IO.puts "Accepted message from #{peername}"

    server_handler(socket, session_key)
  end

  defp get_peername(socket) do
    {:ok, {addr, port}} = :inet.peername(socket)

    addr
    |> :inet_parse.ntoa()
    |> to_string()
  end
end