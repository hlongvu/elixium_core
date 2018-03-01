defmodule UltraDark.ChainState do
  alias UltraDark.Store
  require Exleveldb

  @moduledoc """
    Stores data related to contracts permanently.
  """

  @store_dir ".chainstate"

  def initialize do
    Store.initialize(@store_dir)
  end

  @spec update(String.t(), map) :: :ok | {:error, any}
  def update(contract_address, new_state) do
    fn ref ->
      current_contract_state = case Exleveldb.get(ref, contract_address) do
        {:ok, bin} ->
          :erlang.binary_to_term(bin)
        _ ->
          %{}
      end

      new_contract_state =
        current_contract_state
        |> Map.merge(new_state)
        |> :erlang.term_to_binary

      Exleveldb.put(ref, contract_address, new_contract_state)
    end
    |> Store.transact(@store_dir)
  end

  def get(contract_address) do
    fn ref ->
      {:ok, bin} = Exleveldb.get(ref, contract_address)
      :erlang.binary_to_term(bin)
    end
    |> Store.transact(@store_dir)
  end
end