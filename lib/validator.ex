defmodule Elixium.Validator do
  alias Elixium.Block
  alias Elixium.Utilities
  alias Elixium.KeyPair
  alias Elixium.Store.Ledger
  alias Elixium.BlockEncoder
  alias Elixium.Store.Oracle
  alias Elixium.Transaction

  @moduledoc """
    Responsible for implementing the consensus rules to all blocks and transactions
  """

  @doc """
    A block is considered valid if the index is greater than the index of the previous block,
    the previous_hash is equal to the hash of the previous block, and the hash of the block,
    when recalculated, is the same as what the listed block hash is
  """
  @spec is_block_valid?(Block, number) :: :ok | {:error, any}
  def is_block_valid?(block, difficulty, last_block \\ Ledger.last_block(), pool_check \\ &Oracle.inquire(:"Elixir.Elixium.Store.UtxoOracle", {:in_pool?, [&1]})) do
    if :binary.decode_unsigned(block.index) == 0 do
      with :ok <- valid_coinbase?(block),
           :ok <- valid_transactions?(block, pool_check),
           :ok <- valid_merkle_root?(block.merkle_root, block.transactions),
           :ok <- valid_hash?(block, difficulty),
           :ok <- valid_timestamp?(block),
           :ok <- valid_block_size?(block) do
        :ok
      else
        err -> err
      end
    else
      with :ok <- valid_index(block.index, last_block.index),
           :ok <- valid_prev_hash?(block.previous_hash, last_block.hash),
           :ok <- valid_coinbase?(block),
           :ok <- valid_transactions?(block, pool_check),
           :ok <- valid_merkle_root?(block.merkle_root, block.transactions),
           :ok <- valid_hash?(block, difficulty),
           :ok <- valid_timestamp?(block),
           :ok <- valid_block_size?(block) do
        :ok
      else
        err -> err
      end
    end
  end

  @spec valid_merkle_root?(binary, list) :: :ok | {:error, :invalid_merkle_root}
  defp valid_merkle_root?(merkle_root, transactions) do
    calculated_root =
      transactions
      |> Enum.map(&:erlang.term_to_binary/1)
      |> Utilities.calculate_merkle_root()

    if calculated_root == merkle_root, do: :ok, else: {:error, :invalid_merkle_root}
  end

  @spec valid_index(number, number) :: :ok | {:error, {:invalid_index, number, number}}
  defp valid_index(index, prev_index) when index > prev_index, do: :ok
  defp valid_index(idx, prev), do: {:error, {:invalid_index, prev, idx}}

  @spec valid_prev_hash?(String.t(), String.t()) :: :ok | {:error, {:wrong_hash, {:doesnt_match_last, String.t(), String.t()}}}
  defp valid_prev_hash?(prev_hash, last_block_hash) when prev_hash == last_block_hash, do: :ok
  defp valid_prev_hash?(phash, lbhash), do: {:error, {:wrong_hash, {:doesnt_match_last, phash, lbhash}}}

  @spec valid_hash?(Block, number) :: :ok | {:error, {:wrong_hash, {:too_high, String.t(), number}}}
  defp valid_hash?(b, difficulty) do
    with :ok <- compare_hash(b, b.hash),
         :ok <- beat_target?(b.hash, difficulty) do
      :ok
    else
      err -> err
    end
  end

  defp beat_target?(hash, difficulty) do
    if Block.hash_beat_target?(%{hash: hash, difficulty: difficulty}) do
      :ok
    else
      {:error, {:wrong_hash, {:too_high, hash, difficulty}}}
    end
  end

  @spec compare_hash(Block, String.t()) :: :ok | {:error, {:wrong_hash, {:doesnt_match_provided, String.t(), String.t()}}}
  defp compare_hash(block, hash) do
    computed = Block.calculate_block_hash(block)

    if computed == hash do
      :ok
    else
      {:error, {:wrong_hash, {:doesnt_match_provided, computed, hash}}}
    end
  end

  @spec valid_coinbase?(Block) :: :ok | {:error, :no_coinbase} | {:error, :too_many_coinbase}
  def valid_coinbase?(%{transactions: transactions, index: block_index}) do
    coinbase = hd(transactions)

    with :ok <- coinbase_exist?(coinbase),
         :ok <- is_coinbase?(coinbase),
         :ok <- appropriate_coinbase_output?(transactions, block_index),
         :ok <- one_coinbase?(transactions) do
      :ok
    else
      err -> err
    end
  end

  def one_coinbase?(transactions) do
    one =
      transactions
      |> Enum.filter(& &1.txtype == "COINBASE")
      |> length()
      |> Kernel.==(1)

    if one, do: :ok, else: {:error, :too_many_coinbase}
  end

  def coinbase_exist?(nil), do: {:error, :no_coinbase}
  def coinbase_exist?(_coinbase), do: :ok


  @spec valid_transaction?(Transaction, function) :: :ok | {:error, any}
  def valid_transaction?(transaction, pool_check \\ &Oracle.inquire(:"Elixir.Elixium.Store.UtxoOracle", {:in_pool?, [&1]}))

  @doc """
    Coinbase transactions are validated separately. If a coinbase transaction
    gets here it'll always return true
  """
  def valid_transaction?(%{txtype: "COINBASE"}, _pool_check), do: :ok

  @doc """
    Checks if a transaction is valid. A transaction is considered valid if
    1) all of its inputs are currently in our UTXO pool and 2) all addresses
    listed in the inputs have a corresponding signature in the sig set of the
    transaction. pool_check is a function which tests whether or not a
    given input is in a pool (this is mostly used in the case of a fork), and
    this function must return a boolean.
  """
  def valid_transaction?(transaction, pool_check) do
    with :ok <- correct_tx_id?(transaction),
         :ok <- passes_pool_check?(transaction, pool_check),
         :ok <- tx_addr_match?(transaction),
         :ok <- tx_sigs_valid?(transaction),
         :ok <- utxo_amount_integer?(transaction),
         :ok <- outputs_dont_exceed_inputs?(transaction) do
      :ok
    else
      err -> err
    end
  end

  @spec correct_tx_id?(Transaction) :: :ok | {:error, {:invalid_tx_id, String.t(), String.t()}}
  def correct_tx_id?(transaction) do
    expected_id = Transaction.calculate_hash(transaction)

    if expected_id == transaction.id do
      :ok
    else
      {:error, {:invalid_tx_id, expected_id, transaction.id}}
    end
  end

  @spec passes_pool_check?(Transaction, function) :: :ok | {:error, :failed_pool_check}
  def passes_pool_check?(%{inputs: inputs}, pool_check) do
    if Enum.all?(inputs, & pool_check.(&1)) do
      :ok
    else
      {:error, :failed_pool_check}
    end
  end

  @spec tx_addr_match?(Transaction) :: :ok | {:error, :sig_set_mismatch}
  defp tx_addr_match?(transaction) do
    signed_addresses = Enum.map(transaction.sigs, fn {addr, _sig} -> addr end)

    # Check that all addresses in the inputs are also part of the signature set
    all? =
      transaction.inputs
      |> Enum.map(& &1.addr)
      |> Enum.uniq()
      |> Enum.all?(& Enum.member?(signed_addresses, &1))

    if all?, do: :ok, else: {:error, :sig_set_mismatch}
  end

  @spec tx_sigs_valid?(Transaction) :: :ok | {:error, :invalid_tx_sig}
  defp tx_sigs_valid?(transaction) do
    all? =
      Enum.all?(transaction.sigs, fn {addr, sig} ->
        pub = KeyPair.address_to_pubkey(addr)

        transaction_digest = Transaction.signing_digest(transaction)

        KeyPair.verify_signature(pub, sig, transaction_digest)
      end)

    if all?, do: :ok, else: {:error, :invalid_tx_sig}
  end

  @spec utxo_amount_integer?(Transaction) :: :ok | {:error, :utxo_amount_not_integer}
  def utxo_amount_integer?(transaction) do
    if Enum.all?(transaction.inputs ++ transaction.outputs, & is_integer(&1.amount)) do
      :ok
    else
      {:error, :utxo_amount_not_integer}
    end
  end

  @spec outputs_dont_exceed_inputs?(Transaction) :: :ok | {:error, {:outputs_exceed_inputs, integer, integer}}
  defp outputs_dont_exceed_inputs?(transaction) do
    input_total = Transaction.sum_inputs(transaction.inputs)
    output_total = Transaction.sum_inputs(transaction.outputs)

    if output_total <= input_total do
      :ok
    else
      {:error, {:outputs_exceed_inputs, output_total, input_total}}
    end
  end

  @spec valid_transactions?(Block, function) :: :ok | {:error, {:invalid_transactions, list}}
  def valid_transactions?(%{transactions: transactions}, pool_check \\ &Oracle.inquire(:"Elixir.Elixium.Store.UtxoOracle", {:in_pool?, [&1]})) do
    results = Enum.map(transactions, & valid_transaction?(&1, pool_check))
    if Enum.all?(results, & &1 == :ok), do: :ok, else: {:error, {:invalid_transactions, Enum.filter(results, & &1 != :ok)}}
  end

  @spec is_coinbase?(Transaction) :: :ok | {:error, {:not_coinbase, String.t()}}
  defp is_coinbase?(%{txtype: "COINBASE"}), do: :ok
  defp is_coinbase?(tx), do: {:error, {:not_coinbase, tx.txtype}}

  @spec appropriate_coinbase_output?(list, number) :: :ok | {:error, :invalid_coinbase, integer, integer, integer}
  defp appropriate_coinbase_output?([coinbase | transactions], block_index) do
    total_fees = Block.total_block_fees(transactions)

    reward =
      block_index
      |> :binary.decode_unsigned()
      |> Block.calculate_block_reward()

    amount = hd(coinbase.outputs).amount

    if total_fees + reward == amount do
      :ok
    else
      {:error, {:invalid_coinbase, total_fees, reward, amount}}
    end
  end

  @spec valid_timestamp?(Block) :: :ok | {:error, :timestamp_too_high}
  defp valid_timestamp?(%{timestamp: timestamp}) do
    ftl = Application.get_env(:elixium_core, :future_time_limit)

    current_time =
      DateTime.utc_now()
      |> DateTime.to_unix()

    if timestamp < current_time + ftl, do: :ok, else: {:error, :timestamp_too_high}
  end

  @spec valid_block_size?(Block) :: {:ok} | {:error, :block_too_large}
  defp valid_block_size?(block) do
    block_size_limit = Application.get_env(:elixium_core, :block_size_limit)

    under_size_limit =
      block
      |> BlockEncoder.encode()
      |> byte_size()
      |> Kernel.<=(block_size_limit)

    if under_size_limit, do: :ok, else: {:error, :block_too_large}
  end
end
