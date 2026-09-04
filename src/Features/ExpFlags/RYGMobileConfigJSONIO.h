#import "RYGMobileConfig.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RYGMCNameMappingImportMode) {
    /// The imported JSON becomes RyukGram's complete persisted id_name_mapping
    /// overlay. Any prior imported overlay entries not present in the new file
    /// are removed.
    RYGMCNameMappingImportModeReplace = 0,

    /// Merge the imported JSON with the mapping already available to RyukGram.
    /// Existing configs/params are preserved when absent from the import; the
    /// imported file wins on config-name or param-name conflicts.
    RYGMCNameMappingImportModeMerge,
};

FOUNDATION_EXPORT NSString *const RYGMCRuntimeSnapshotSchemaV1;

@interface RYGMobileConfig (RYGJSONIO)
- (nullable NSString *)ryg_nativeDataDirectory;
- (nullable NSString *)ryg_nativeNameMappingPath;
- (nullable NSString *)ryg_nativeOverridesJSONPath;
- (BOOL)ryg_importNameMappingData:(NSData *)data error:(NSError **)error;
- (BOOL)ryg_importNameMappingData:(NSData *)data
                             mode:(RYGMCNameMappingImportMode)mode
                            error:(NSError **)error;
- (nullable NSData *)ryg_exportNameMappingData:(NSError **)error;
- (BOOL)ryg_importAndApplyOverridesData:(NSData *)data
                           appliedCount:(NSUInteger *)appliedCount
                                  error:(NSError **)error;
- (nullable NSData *)ryg_exportOverridesData:(NSError **)error;
/// Exports every typed row from Instagram's live table together with its
/// effective value and any RyukGram-owned override. Names are decoration only.
- (nullable NSData *)ryg_exportRuntimeSnapshotData:(NSError **)error;
/// Restores only the explicit override set recorded in a runtime snapshot. The
/// effective/server values in the file are diagnostic and are never mass-forced.
- (BOOL)ryg_importRuntimeSnapshotOverridesData:(NSData *)data
                                   appliedCount:(NSUInteger *)appliedCount
                                          error:(NSError **)error;
- (BOOL)ryg_isRuntimeSnapshotData:(NSData *)data;
@end

/// Persistence-to-native bridge kept separate from JSON parsing/import. It has
/// no constructor and installs no hooks; callers explicitly request a flush
/// after the context manager has exposed its authoritative <user>.data path.
@interface RYGMobileConfig (RYGPersistedJSONSync)
- (BOOL)ryg_syncPersistedJSONToNativeDataDirectory;
@end

NS_ASSUME_NONNULL_END
