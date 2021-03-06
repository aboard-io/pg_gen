[
  inputs: ["*.{ex,exs}", "priv/*/seeds.exs", "{config,lib,test}/**/*.{ex,exs}"],
  subdirectories: ["priv/*/migrations"],
  locals_without_parens: [
    def: :*,
    field: :*,
    belongs_to: :*,
    has_many: :*,
    has_one: :*,
    many_to_many: :*,
    object: :*,
    value: :*,
    resolve: :*,
    arg: :*,
    enum: :*,
    import_types: :*,
  ]
]
