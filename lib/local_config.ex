defmodule PgGen.LocalConfig do
  def get_db do
    app_name = get_app_name()

    app = app_name |> to_string |> Macro.underscore() |> String.to_atom()

    case Application.fetch_env(
           app,
           get_repo_atom()
         ) do
      :error ->
        %{database: "", hostname: "localhost", password: "postgres", username: "postgres"}

      {:ok, db_env} ->
        db_env
        |> Enum.into(%{})
    end
  end

  def get_authenticator_db do
    app_name = get_app_name()

    app = app_name |> to_string |> Macro.underscore() |> String.to_atom()

    case Application.fetch_env(
           app,
           get_authenticator_repo_atom()
         ) do
      :error ->
        nil

      {:ok, db_env} ->
        db_env
        |> Enum.into(%{})
    end
  end

  def get_app_name do
    line = "mix.exs" |> File.stream!() |> Enum.take(1)
    [name | _] = Regex.run(~r/(\S+)(?=\.)/, to_string(line))

    name || ""
  end

  def get_repo_atom do
    {repo, _} = Code.eval_string("#{get_app_name()}.Repo")
    repo
  end

  def get_authenticator_repo_atom do
    {repo, _} = Code.eval_string("#{get_app_name()}.AuthenticatorRepo")

    case Code.ensure_compiled(repo) do
      {:module, _} -> repo
      {:error, _} -> nil
    end
  end

  def get_contexts_path do
    fragment = get_app_name() |> Macro.underscore()
    "lib/#{fragment}/contexts"
  end

  def get_repo_path do
    fragment = get_app_name() |> Macro.underscore()
    "lib/#{fragment}/repo"
  end

  def get_graphql_schema_path do
    fragment = get_app_name() |> Macro.underscore()
    "lib/#{fragment}_web/schema"
  end

  def get_graphql_resolver_path do
    "#{get_graphql_schema_path()}/resolvers"
  end
end
