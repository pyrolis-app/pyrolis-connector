defmodule PyrolisConnectorTest do
  use ExUnit.Case
  doctest PyrolisConnector

  test "greets the world" do
    assert PyrolisConnector.hello() == :world
  end
end
