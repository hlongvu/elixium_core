defmodule Elixium.Node.Supervisor do
  alias Elixium.Store.Oracle
  use Supervisor
  require Logger

  @moduledoc """
    Responsible for getting peer information and launching connection handlers
  """

  def start_link, do: start_link(self())
  def start_link([router_pid]), do: start_link(router_pid)
  def start_link([nil]), do: start_link(self())

  def start_link(router_pid) do
    port = Application.get_env(:elixium_core, :port)
    Supervisor.start_link(__MODULE__, [router_pid, port], name: __MODULE__)
  end

  def init([router_pid, port]) do
    Oracle.start_link(Elixium.Store.Peer)
    :pg2.create(:p2p_handlers)

    case open_socket(port) do
      :error -> :error
      socket ->
        handlers = generate_handlers(socket, router_pid, find_potential_peers())

        children = handlers ++ [Elixium.HostAvailability.Supervisor]

        Supervisor.init(children, strategy: :one_for_one)
    end
  end

  defp generate_handlers(socket, router_pid, peers) do
    max_bidirectional = Application.get_env(:elixium_core, :max_bidirectional_connections)
    max_inbound = Application.get_env(:elixium_core, :max_inbound_connections)

    bidirectional =
      for i <- 1..max_bidirectional do
        %{
          id: :"ConnectionHandler#{i}",
          start: {
            Elixium.Node.ConnectionHandler,
            :start_link,
            [socket, router_pid, peers, i, true]
          },
          type: :worker,
          restart: :permanent
        }
      end

    inbound =
      for i <- (max_bidirectional + 1)..max_inbound do
        %{
          id: :"ConnectionHandler#{i}",
          start: {
            Elixium.Node.ConnectionHandler,
            :start_link,
            [socket, router_pid, peers, i]
          },
          type: :worker,
          restart: :permanent
        }
      end

    bidirectional ++ inbound
  end

  @spec open_socket(pid) :: pid | :error
  defp open_socket(port) do
    options = [:binary, reuseaddr: true, active: false]

    case :gen_tcp.listen(port, options) do
      {:ok, socket} ->
        Logger.info("Opened listener socket on port #{port}.")
        socket
      _ ->
        Logger.warn("Listen socket not started, something went wrong.")
        :error
    end
  end


  # Either returns known peers from our peer storage or gets seed peers
  # from config
  @spec find_potential_peers :: List | :not_found
  defp find_potential_peers do
    case Oracle.inquire(:"Elixir.Elixium.Store.PeerOracle", {:load_known_peers, []}) do
      [] -> seed_peers()
      peers -> peers
    end
  end

  @doc """
    Returns a list of seed peers based on config
  """
  @spec seed_peers :: List
  def seed_peers do
    :elixium_core
    |> Application.get_env(:seed_peers)
    |> Enum.map(&peerstring_to_tuple/1)
  end

  @doc """
    On Connection, fetch our public ip
  """
  @spec fetch_public_ip :: String.t()
  def fetch_public_ip do
    api_url =  'https://api.ipify.org?format=json'

    case :httpc.request(api_url) do
      {:ok, {{'HTTP/1.1', 200, 'OK'}, _headers, body}} -> Jason.decode!(body)
      {:error, _} -> :not_found
    end
  end

  @doc """
    On Connection, fetch our local ip
  """
  @spec fetch_local_ip() :: String.t()
  def fetch_local_ip do
    {:ok, adapter_list} = :inet.getifaddrs()

    adapter_list
    |> Enum.flat_map(fn {_adapter, ip_list} ->
      ip_list
      |> Enum.map(&validate_ip_range/1)
      |> Enum.reject(& &1 == :ok || &1 == '127.0.0.1')
    end)
    |> List.first()
  end

  defp validate_ip_range(key) do
    case key do
      {:addr, address} ->
        size =
          address
          |> Tuple.to_list
          |> Enum.count

        validate_ip(address, size)
      _ -> :ok
    end
  end

  defp validate_ip(address, size) when size == 4, do: :inet_parse.ntoa(address)
  defp validate_ip(_address, size) when size !== 4, do: :ok

  def validate_own_ip_port(peer, ip, port, port_conf) do
    peer === ip && port === port_conf
  end

  @doc """
    Given a peer supervisor, return a list of all the
    handlers that are currently connected to another peer
  """
  @spec connected_handlers :: List
  def connected_handlers do
    :p2p_handlers
    |> :pg2.get_members()
    |> Enum.filter(fn p ->
      p
      |> Process.info()
      |> Keyword.get(:dictionary)
      |> Keyword.has_key?(:connected)
    end)
  end

  @doc """
    Broadcast a message to all peers
  """
  @spec gossip(String.t(), map) :: none
  def gossip(type, message) do
    Enum.each(connected_handlers(), &(send(&1, {type, message})))
  end

  # Converts from a colon delimited string to a tuple containing the
  # ip and port. "127.0.0.1:3000" becomes {'127.0.0.1', 3000}
  defp peerstring_to_tuple(peer) do
    [ip, port] = String.split(peer, ":")
    ip = String.to_charlist(ip)

    port =
      case Integer.parse(port) do
        {port, _} -> port
        :error -> nil
      end

    {ip, port}
  end
end
