#![allow(non_snake_case)]

#[path = "AvatarRepository.rs"]
pub mod AvatarRepository;
#[path = "ChatHistoryManager.rs"]
pub mod ChatHistoryManager;
#[path = "CustomEmojiRepository.rs"]
pub mod CustomEmojiRepository;
#[path = "MemoryAutoSaveCandidateRepository.rs"]
pub mod MemoryAutoSaveCandidateRepository;
#[path = "MemoryRepository.rs"]
pub mod MemoryRepository;
#[path = "RuntimeStorageRepository.rs"]
pub mod RuntimeStorageRepository;
#[path = "UIHierarchyManager.rs"]
pub mod UIHierarchyManager;
#[path = "UsageStatisticsStore.rs"]
pub mod UsageStatisticsStore;
#[path = "UserMarkdownRepository.rs"]
pub mod UserMarkdownRepository;

// WorkflowRepository moved to operit-workflow-core; keep the old path working.
pub use operit_workflow_core::WorkflowRepository;

pub use AvatarRepository::*;
pub use ChatHistoryManager::*;
pub use CustomEmojiRepository::*;
pub use MemoryAutoSaveCandidateRepository::*;
pub use MemoryRepository::*;
pub use RuntimeStorageRepository::*;
pub use UIHierarchyManager::*;
pub use UsageStatisticsStore::*;
pub use UserMarkdownRepository::*;
