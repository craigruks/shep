%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r/deps/]
      },
      checks: %{
        enabled: [
          # Readability
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.MaxLineLength, [max_length: 100, ignore_urls: true]},

          # Warning
          {Credo.Check.Warning.IoInspect, []},

          # Custom checks
          {Factory.Checks.NoAtomFromInput, []},
          {Factory.Checks.PublicDoc, []}
        ]
      }
    }
  ]
}
