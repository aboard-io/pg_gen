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

  def get_app_name do
    line = "mix.exs" |> File.stream!() |> Enum.take(1)
    [name | _] = Regex.run(~r/(\S+)(?=\.)/, to_string(line))

    name
  end

  def get_repo_atom do
    {repo, _} = Code.eval_string("#{get_app_name()}.Repo")
    repo
  end

  def get_repo_path do
    fragment = get_app_name() |> Macro.underscore()
    "lib/#{fragment}/models"
  end
end
