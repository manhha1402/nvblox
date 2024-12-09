/*
Copyright 2024 NVIDIA CORPORATION

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
#include "nvblox/map/blocks_to_update_tracker.h"

namespace nvblox {

/// Safety vent if size is growing too much. This should not happen as long as
/// the indices are consumed.
void clearIfTooLarge(Index3DSet& set, const std::string& name) {
  constexpr size_t kMaxSize = 100'000;
  if (set.size() > kMaxSize) {
    LOG(ERROR) << "IndexSet " << name << " is too large: " << set.size()
               << " > " << kMaxSize
               << ". This should normally not happen. Clearing the set";
    set.clear();
  }
}

void BlocksToUpdateTracker::addBlocksToUpdate(
    const std::vector<Index3D>& blocks_to_update) {
  // Function definition to update blocks.
  auto funct = [&](const std::vector<Index3D> vec) -> void {
    esdf_blocks_to_update_.insert(vec.begin(), vec.end());
    mesh_blocks_to_update_.insert(vec.begin(), vec.end());
    layer_streamer_blocks_to_update_.insert(vec.begin(), vec.end());

    if (hasFreespaceLayer(projective_layer_type_)) {
      freespace_blocks_to_update_.insert(vec.begin(), vec.end());
    }
  };

  clearIfTooLarge(esdf_blocks_to_update_, "esdf");
  clearIfTooLarge(mesh_blocks_to_update_, "mesh");
  clearIfTooLarge(layer_streamer_blocks_to_update_, "layer_streamer");
  clearIfTooLarge(freespace_blocks_to_update_, "freespace");

  // Synchronize (wait for other async calls to finish) and
  // then call the update function asynchronous.
  future_.wait();
  future_ = std::async(std::launch::async, funct, blocks_to_update);
}

void BlocksToUpdateTracker::removeBlocksToUpdate(
    const std::vector<Index3D>& blocks_to_remove) {
  // Function definition to remove blocks.
  auto funct = [&](const std::vector<Index3D> vec) -> void {
    for (const Index3D& idx : vec) {
      esdf_blocks_to_update_.erase(idx);
      mesh_blocks_to_update_.erase(idx);
      layer_streamer_blocks_to_update_.erase(idx);

      if (hasFreespaceLayer(projective_layer_type_)) {
        freespace_blocks_to_update_.erase(idx);
      }
    }
  };

  // Synchronize (wait for other async calls to finish) and
  // then call the removal function asynchronous.
  future_.wait();
  future_ = std::async(std::launch::async, funct, blocks_to_remove);
}

std::vector<Index3D> BlocksToUpdateTracker::getBlocksToUpdate(
    BlocksToUpdateType blocks_to_update_type) const {
  // Synchronize (wait for async calls modifying the update sets to finish).
  future_.wait();

  // Return the blocks to update.
  switch (blocks_to_update_type) {
    case BlocksToUpdateType::kEsdf:
      return {esdf_blocks_to_update_.begin(), esdf_blocks_to_update_.end()};
    case BlocksToUpdateType::kMesh:
      return {mesh_blocks_to_update_.begin(), mesh_blocks_to_update_.end()};
    case BlocksToUpdateType::kFreespace:
      return {freespace_blocks_to_update_.begin(),
              freespace_blocks_to_update_.end()};
    case BlocksToUpdateType::kLayerStreamer:
      return {layer_streamer_blocks_to_update_.begin(),
              layer_streamer_blocks_to_update_.end()};
    default:
      LOG(FATAL) << "BlocksToUpdateType not implemented";
      break;
  }
}

void BlocksToUpdateTracker::markBlocksAsUpdated(
    BlocksToUpdateType blocks_to_update_type) {
  // Function definition to mark blocks as updated.
  auto funct = [&](BlocksToUpdateType type) -> void {
    switch (type) {
      case BlocksToUpdateType::kEsdf:
        esdf_blocks_to_update_.clear();
        break;
      case BlocksToUpdateType::kMesh:
        mesh_blocks_to_update_.clear();
        break;
      case BlocksToUpdateType::kFreespace:
        freespace_blocks_to_update_.clear();
        break;
      case BlocksToUpdateType::kLayerStreamer:
        layer_streamer_blocks_to_update_.clear();
        break;
      default:
        LOG(FATAL) << "BlocksToUpdateType not implemented";
        break;
    }
  };

  // Synchronize (wait for other async calls to finish) and
  // then call the mark as updated function asynchronous.
  future_.wait();
  future_ = std::async(std::launch::async, funct, blocks_to_update_type);
}

}  // namespace nvblox
