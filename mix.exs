defmodule Elixium.Mixfile do
  use Mix.Project

  def project do
    [
      app: :elixium_core,
      version: "0.6.2",
      elixir: "~> 1.7",
      elixirc_paths: ["lib"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Elixium Core",
      description: description(),
      source_url: "https://github.com/elixium/elixium_core",
      homepage_url: "https://elixiumnetwork.org",
      package: package(),
      application: application()
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exleveldb, "~> 0.12.2"},
      {:keccakf1600, "~> 2.0.0"},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false},
      {:strap, "~> 0.1.1"},
      {:jason, "~> 1.0"}
    ]
  end

  defp description do
    "The core package for the Elixium blockchain, containing all the modules needed to run the chain"
  end

  defp package() do
    [
      name: "elixium_core",
      files: ["lib", "mix.exs", "README*", "LICENSE*", "priv"],
      maintainers: ["Alex Dovzhanyn", "Zac Garby", "Nijinsha Rahman", "Matthew Eaton"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/elixium/elixium_core"}
    ]
  end

  def application do
    [
      env: [
        # Total amount of tokens that will ever exist.
        total_token_supply: 1_000_000_000.0,

        # Block at which last block reward will be distributed. Logic behind this
        # number is to have tokens distributed over X period of time. We're going for
        # a total emission period of 10 years. 10 years at 2 minutes per block gives
        # us this 2_628_000 number.
        block_at_full_emission: 2_628_000,

        sigma_full_emission: sigma_full_emission_blocks(2_628_000),

        # Amount of seconds we want to spend mining each block
        target_solvetime: 120,

        diff_rebalance_offset: 10_080,

        # Number of blocks in difficulty retargeting window
        retargeting_window: 60,

        # Maximum number of seconds ahead of our current time that a blocks
        # timestamp can be and still be considered valid.
        future_time_limit: 360,

        ghost_protocol_version: "v1.0",

        seed_peers: [
          "206.189.103.38:31013",
          "142.93.158.121:31013",
          "142.93.152.227:31013",
          "139.59.13.96:31013",
        ],

        address_version: "EX0",

        # 8 Megabyte block size
        block_size_limit: 8_388_608,

        data_path: "~/.elixium",

        port: 31013,

        max_bidirectional_connections: 10,

        max_inbound_connections: 90
      ]
    ]
  end

  # Sigma of the block number @block_at_full_emission. Used in emission algorithm
  defp sigma_full_emission_blocks(0), do: 0
  defp sigma_full_emission_blocks(n) do
    n + sigma_full_emission_blocks(n - 1)
  end
end
