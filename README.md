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

You can run it once, via mix tasks, to generate files and call it a day.

```bash
# To generate the ecto schema
mix pg_gen.generate_ecto --schema app_public

# To generate the absinthe schema
mix pg_gen.generate_absinthe --schema app_public
```

You can also use it more like Postgraphile.

## Using in a project

### 1. Install as a dependency to `mix.exs`

```elixir
  defp deps do
    [
      # add to your deps:
      {:pg_gen, path: "../path_to_pg_gen"},
      {:absinthe, "~> 1.6"},
      {:absinthe_plug, "~> 1.5"},
      {:absinthe_phoenix, "~> 2.0"},
      {:dataloader, "~> 1.0.0"},
      {:base62_uuid, "~> 2.0.0", github: "adampash/base62_uuid"},
      {:absinthe_error_payload, "~> 1.1"},
    ]
```

Then run:

```bash
mix deps.get
```

In this example, I'm using a forked UUID62 lib with an alphabet order that matches a corresponding Node library so they can interop.

### 2. Configure your database

This is _relatively_ normal Phoenix+Ecto, with the exception that you set up
configure it twice; once with "authenticator" credentials and once with your
root credentials. . Set up the db credentials, db name, etc.

The way this currently works is you configure two repos, like so:

```elixir
config :example, Example.Repo,
  username: "postgres",
  password: "postgres",
  database: "example",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Configure your database
config :example, Example.AuthenticatorRepo,
  username: "postgres_authenticator",
  password: "password",
  database: "example",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
```

The `AuthenticatorRepo` is what PgGen uses to run the introspection query,
which generates all the code for the GraphQL server (from Ecto to Absinthe). It
assumes it's a db role which has the default permissions for RLS. If a user
doesn't have permissions to read a table, that table won't be in your
public-facing schema.

(If you weren't planning to use RLS, you could probably just duplicate the
config between the two. It would be sensible to make this configurable.)

If you are using the `AuthenticatorRepo`, you'll want to add the very barebones
module like:

```elixir
defmodule Example.AuthenticatorRepo do
  use Ecto.Repo,
    otp_app: :example,
    adapter: Ecto.Adapters.Postgres
end
```

### 3. Configure your application

To the children in your application supervisor, add your elevated repo if using (your
default repo should already be here) and PgGen:

```elixir
    chilren = [
      # ..others...
      # Start the Elevated Ecto repository
      Example.AuthenticatorRepo,
      # Start PgGen
      {PgGen.Supervisor, schema: "app_public", output_path: "../../aboard/data/elixir-schema.graphql"},
    ]
```

You'll notice that PgGen requires setting your scheme (defaults to `public` if
you don't) and a path to write a generated GraphQL schema. This is handy for dx
tooling.

### 3. Configure RLS (optional)

If you're coming from Postgraphile, you're probably using RLS (and already did
the `AuthenticatorRepo` bit above). In order to execute queries using RLS with
Ecto, you need to do wrap your DB queries in transactions that set the user
role. My code that does this is in `Example.Repo` and looks like:

```elixir
  alias Ecto.Adapters.SQL

  @doc """
  A function to wrap Ecto queries in transactions to work with Postgres
  row-level security. Requires a session_id
  """
  def as_user(session_id, txn)
      when is_binary(session_id) and is_function(txn) do
    transaction(fn ->
      SQL.query(
        Example.Repo,
        """
        SELECT
          set_config('role', 'authenticated_user_role', true),
          set_config('jwt.claims.session_id', $1, true)
        """,
        [
          session_id
        ]
      )

      txn.()
    end)
  end
```

Then to wrap your GraphQL requests in these transactions, you can use this very
simple wrapper plug:

```elixir
defmodule AbsintheAsUserPlug do
  require Logger
  def init(options), do: Absinthe.Plug.init(options)

  def call(%{assigns: %{session_id: session_id}} = conn, opts) do
    Logger.debug("Running absinthe in transaction")

    {:ok, conn} =
      Example.Repo.as_user(session_id, fn ->
        Absinthe.Plug.call(conn, opts)
      end)

    Logger.debug("Finished running transaction")

    conn
  end

  def call(conn, opts) do
    Absinthe.Plug.GraphiQL.call(conn, opts)
  end
end
```

I'm not going to go into auth here, but the session id would, of course, be
necessary for this whole thing to work.

### 4. Configure Absinthe

In `router.ex`:

```elixir
  scope "/" do
    pipe_through(:api)

    # forward("/graphiql", GraphiqlAsUserPlug, schema: ExampleWeb.Schema.Types)
    # forward("/graphiql", Absinthe.Plug.GraphiQL,
    forward("/graphiql", GraphiqlAsUserPlug,
      schema: ExampleWeb.Schema,
      interface: :simple,
      socket: ExampleWeb.UserSocket
    )

    # forward("/graphql", Absinthe.Plug, schema: ExampleWeb.Schema)
    forward("/graphql", AbsintheAsUserPlug, schema: ExampleWeb.Schema)
  end
```

In `endpoint.ex`, to set up subscriptions:

```elixir
  socket "/websocket", ExampleWeb.UserSocket,
    websocket: true,
    longpoll: false,
    check_origin: ["http://localhost:5678"]
```

The code is not always pretty. I've been spelunking a lot, but it's been pretty
interesting and fun. Please feel free to play around, submit PRs, etc.

## Things currently on my to-do list:

- [x] Mutations for the Absinthe schema. Currently only supports read.
- [x] Cursor-based pagination
- [x] Not relay support, but support for the `nodes` structure Postgraphile supports. E.g.,

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

- [x] Support exposing postgres functions
- [ ] Options for how codegen works. E.g., optional resolve methods. Right now
      I'm just using `dataloader`, which helps batch db queries and avoids N+1.
- [x] Overrides/customization. E.g., it'd be nice to be able to write some
      config or override code that allows you to provide your own resolver for a
      specific field, etc. Similar to above.
- [x] A version that doesn't generate/write code to files, but instead just
      mounts an engine that dynamically updates (and could hot reload in dev mode).
      José Valim's answer to [this StackOverflow
      question](https://stackoverflow.com/questions/13223238/how-do-you-create-and-load-modules-dynamically-at-runtime-in-elixir-or-erlang)
      lays out how this could work. It doesn't seem that difficult tbh, and would
      allow you to use this similarly to how Postgraphile works.
- [x] Subscriptions. Have not toyed with this idea yet but seems like you could
      generate subscriptions if you wanted... Also maybe not worth doing
      programatically, since they're more use-case based.
- [x] RLS. I actually have this working in an example app by
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
