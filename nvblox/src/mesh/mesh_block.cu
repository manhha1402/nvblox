/*
Copyright 2022 NVIDIA CORPORATION

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "nvblox/mesh/mesh_block.h"

namespace nvblox {

MeshBlock::MeshBlock(MemoryType memory_type)
    : vertices(memory_type),
      normals(memory_type),
      colors(memory_type),
      triangles(memory_type) {}

void MeshBlock::clear() {
  vertices.clearNoDeallocate();
  normals.clearNoDeallocate();
  triangles.clearNoDeallocate();
  colors.clearNoDeallocate();
}

MeshBlock::Ptr MeshBlock::allocate(MemoryType memory_type) {
  return std::make_shared<MeshBlock>(memory_type);
}

MeshBlock::Ptr MeshBlock::allocateAsync(MemoryType memory_type,
                                        const CudaStream&) {
  return allocate(memory_type);
}

size_t MeshBlock::size() const { return vertices.size(); }

size_t MeshBlock::capacity() const { return vertices.capacity(); }

void MeshBlock::expandColorsToMatchVerticesAsync(
    const CudaStream& cuda_stream) {
  colors.reserveAsync(vertices.capacity(), cuda_stream);
  colors.resizeAsync(vertices.size(), cuda_stream);
}

void MeshBlock::copyFromAsync(const MeshBlock& other,
                              const CudaStream& cuda_stream) {
  vertices.copyFromAsync(other.vertices, cuda_stream);
  normals.copyFromAsync(other.normals, cuda_stream);
  colors.copyFromAsync(other.colors, cuda_stream);
  triangles.copyFromAsync(other.triangles, cuda_stream);
}

void MeshBlock::copyFrom(const MeshBlock& other) {
  copyFromAsync(other, CudaStreamOwning());
}

// Set the pointers to point to the mesh block.
CudaMeshBlock::CudaMeshBlock(MeshBlock* block) {
  CHECK_NOTNULL(block);
  vertices = block->vertices.data();
  normals = block->normals.data();
  triangles = block->triangles.data();
  colors = block->colors.data();

  vertices_size = block->vertices.size();
  triangles_size = block->triangles.size();
}

size_t sizeInBytes(const MeshBlock* mesh_block) {
  return mesh_block->vertices.size() * sizeof(Vector3f) +  // NOLINT
         mesh_block->normals.size() * sizeof(Vector3f) +   // NOLINT
         mesh_block->colors.size() * sizeof(Color) +       // NOLINT
         mesh_block->triangles.size() * sizeof(int);
}

}  // namespace nvblox
