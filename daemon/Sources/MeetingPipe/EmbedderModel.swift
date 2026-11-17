import Foundation

/// STOR15: the Hugging Face repo `mp` embeds with (`mp ask`, `mp mcp-serve`, `mp actions --cluster`).
///
/// The daemon never loads it; it only needs to know the name so Storage's **Evict unused** keeps it.
/// Under regulated mode a missing embedder cannot be downloaded (the egress guard is armed), so
/// Ask and MCP serve fail closed until a manual `mp prefetch-model`. Pinned against
/// `embed_index.DEFAULT_EMBED_MODEL` by `StorageStatsTests.test_the_embedder_id_matches_the_pipeline_default`,
/// so a model swap on the Python side cannot leave the daemon evicting the new embedder.
enum EmbedderModel {
    static let id = "mlx-community/multilingual-e5-small-mlx"
}
