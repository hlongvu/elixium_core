defmodule Elixium.P2P.GhostProtocol.Message do

  def build(type, message_map) do
    message =
      message_map
      |> Map.keys()
      |> Enum.map(& create_param(&1, Map.get(message_map, &1)))
      |> Enum.join("|")

    ["Ghost", byte_size(message), type, message]
    |> Enum.join("|")
  end

  defp create_param(key, value) when is_number(value) do
    to_param_name(key) <> ":+" <> Integer.to_string(value)
  end

  defp create_param(key, value) when is_bitstring(value) do
    to_param_name(key) <> ":^" <> value
  end

  defp create_param(key, value) when is_list(value) do

  end

  defp to_param_name(key) do
    key
    |> Atom.to_string()
    |> String.upcase()
  end

end
