defmodule EctoGen.ContextGenerator do
  alias PgGen.Utils

  def generate({:enum_types, _}, _) do
    nil
  end

  def generate(
        %{
          name: name
        } = table,
        app_name
      ) do
    app_module_name = Inflex.singularize(app_name) |> Macro.camelize()
    table_name = Inflex.singularize(name) |> Macro.camelize()

    module = """
    defmodule #{app_module_name}.Contexts.#{table_name} do

     import Ecto.Query, warn: false
     alias #{app_module_name}.Repo

     alias #{app_module_name}.Repo.#{table_name}

       #{generate_selectable(table)}
       #{generate_insertable(table)}
       #{generate_updatable(table)}
       #{generate_deletable(table)}

      # dataloader
      def data() do
        Dataloader.Ecto.new(#{app_name}.Repo, query: &query/2)
      end

      def query(queryable, _params) do
        queryable
      end
    end
    """

    {name, Utils.format_code!(module)}
  end

  def generate_selectable(%{selectable: true, name: name}) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    """
    def get_#{Inflex.singularize(lower_case_table_name)}!(id) do
      Repo.get!(#{table_name}, id)
    end

    def list_#{Inflex.pluralize(lower_case_table_name)} do
      Repo.all(#{table_name})
    end
    """
  end

  def generate_selectable(_), do: ""

  def generate_insertable(%{selectable: true, name: name}) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = Inflex.singularize(lower_case_table_name)

    """
    def create_#{singular_lowercase}(attrs) do
      %#{table_name}{}
      |> #{table_name}.changeset(attrs)
      |> Repo.insert(returning: true)
    end
    """
  end

  def generate_insertable(_), do: ""

  def generate_updatable(%{selectable: true, name: name}) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = Inflex.singularize(lower_case_table_name)

    """
    def update_#{singular_lowercase}(%#{table_name}{} = #{singular_lowercase}, attrs) do
      #{singular_lowercase}
      |> #{table_name}.changeset(attrs)
      |> Repo.update(returning: true)
    end

    """
  end

  def generate_updatable(_), do: ""

  def generate_deletable(%{selectable: true, name: name}) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = Inflex.singularize(lower_case_table_name)

    """
    def delete_#{singular_lowercase}(%#{table_name}{} = #{singular_lowercase}) do
      #{singular_lowercase}
      |> Repo.delete()
    end
    """
  end

  def generate_deletable(_), do: ""

  def get_table_names(name) do
    %{
      table_name: name |> Inflex.singularize() |> Macro.camelize(),
      lower_case_table_name: String.downcase(name)
    }
  end
end
