defmodule Minecraft.WorldTest do
  use ExUnit.Case, async: true

  test "Generating chunks works" do
    assert %Minecraft.Chunk{} = Minecraft.World.get_chunk(22, 59)
  end

  describe "World.Storage" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mc_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "save and load chunk data", %{dir: dir} do
      chunk_data = %{x: 5, z: -3, sections: <<1, 2, 3, 4, 5>>}
      :ok = Minecraft.World.Storage.save_chunk(dir, 5, -3, chunk_data)
      assert {:ok, ^chunk_data} = Minecraft.World.Storage.load_chunk(dir, 5, -3)
    end

    test "load missing chunk returns :error", %{dir: dir} do
      assert :error = Minecraft.World.Storage.load_chunk(dir, 99, 99)
    end
  end
end
