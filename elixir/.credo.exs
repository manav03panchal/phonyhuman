%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: %{
        extra: [
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 17]}
        ]
      }
    }
  ]
}
