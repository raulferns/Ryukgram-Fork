// Embed the verified MobileConfig mappings as ordinary Mach-O sections.
//
// Do not pass the raw JSON files through *_LDFLAGS. Theos invokes the C++
// driver for the final link, and a split/mis-forwarded -sectcreate argument
// makes clang/ld treat the JSON as an input object ("unknown file type").
// Compiling this Objective-C translation unit lets clang's integrated assembler
// create the sections inside a normal arm64 object before the final link.

__asm__(
    ".section __DATA,__idmap,regular,no_dead_strip\n"
    ".p2align 4\n"
    ".incbin \".theos/generated/id_name_mapping.v8.json\"\n"
    ".section __DATA,__idmap439,regular,no_dead_strip\n"
    ".p2align 4\n"
    ".incbin \"src/BundleAssets/id_name_mapping_internal439.json\"\n"
    ".section __TEXT,__text,regular,pure_instructions\n"
);
