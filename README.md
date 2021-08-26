# PgGen

An experiment/tool for dynamically generating Ecto and Absinthe schemas from a
Postgres database. Relies heavily on ideas from Postgraphile, and very
explicitly on the [introspection
query](https://github.com/graphile/graphile-engine/blob/v4/packages/graphile-build-pg/src/plugins/introspectionQuery.js)
that Postgraphile uses introspect the database.

## Installation

This isn't on Hex but if you wanted to try it out locally, you can clone the
repo and use the path option to install it in a Phoenix app like so:

```elixir
def deps do
  [
    {:pg_gen, path: "/path/to/local/pg_gen"},
  ]
end
```

Currently it works via mix tasks, and it uses the Ecto config in the app you're
running it from. So from the command line, in the directory of your Phoenix
app, you'd run:

```bash
# To generate the ecto schema
mix pg_gen.generate_ecto --schema app_public

# To generate the absinthe schema
mix pg_gen.generate_absinthe --schema app_public
```

The code is not always pretty. I've been spelunking a lot, but it's been pretty
interesting and fun. Please feel free to play around, submit PRs, etc.

## Things currently on my to-do list:

- [x] Mutations for the Absinthe schema. Currently only supports read.
- [ ] Cursor-based pagination
- [ ] Not relay support, but support for the `nodes` structure Postgraphile supports. E.g.,

  ```graphql
  query {
    workflows {
      pageInfo {
        startCursor
        endCursor
      }
      nodes {
        id
        name
        # ...etc.
      }
    }
  }
  ```

- [ ] Support exposing postgres functions
- [ ] Options for how codegen works. E.g., optional resolve methods. Right now
      I'm just using `dataloader`, which helps batch db queries and avoids N+1.
- [ ] Overrides/customization. E.g., it'd be nice to be able to write some
      config or override code that allows you to provide your own resolver for a
      specific field, etc. Similar to above.
- [ ] A version that doesn't generate/write code to files, but instead just
      mounts an engine that dynamically updates (and could hot reload in dev mode).
      José Valim's answer to [this StackOverflow
      question](https://stackoverflow.com/questions/13223238/how-do-you-create-and-load-modules-dynamically-at-runtime-in-elixir-or-erlang)
      lays out how this could work. It doesn't seem that difficult tbh, and would
      allow you to use this similarly to how Postgraphile works.
- [ ] Subscriptions. Have not toyed with this idea yet but seems like you could
      generate subscriptions if you wanted... Also maybe not worth doing
      programatically, since they're more use-case based.
- [ ] RLS. I actually have this working in an example app by
      wrapping the Absinthe plug in an ecto transaction, but it's not
      currently in the repo.
- [ ] RLS eject. It seems interesting and somewhat worthwhile bring the RLS
      checks into generated app code using Ecto `fragment`s.

## Development

Most of my testing is against the existing Aboard database.

```bash
mix test.watch
```

---

If [available in Hex](https://hex.pm/docs/publish) (again, it's not), the package can be installed
by adding `pg_gen` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pg_gen, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/absinthe_gen](https://hexdocs.pm/absinthe_gen).
