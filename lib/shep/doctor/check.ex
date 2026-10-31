defmodule Shep.Doctor.Check do
  @moduledoc "One `Shep.Doctor` result: what was checked, whether it passed, and the fix if not."

  @enforce_keys [:name, :ok?, :detail]
  defstruct [:name, :ok?, :detail, fix: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          ok?: boolean(),
          detail: String.t(),
          fix: String.t() | nil
        }
end
