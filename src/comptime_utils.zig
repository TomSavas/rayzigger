pub fn getFuncsWithReturnType(comptime fileType: type, comptime parameterType: type, comptime returnType: type) []*const fn (parameterType) returnType {
    // TODO: overallocates, but not sure how that impacts the actual array that ends up in the binary
    comptime var funcs = [1]*const fn (parameterType) returnType{undefined} ** 256;
    comptime var i = 0;

    inline for (@typeInfo(fileType).Struct.decls) |field| {
        if (!field.is_pub) {
            continue;
        }

        // Don't quite understand why this song and dance between
        // TypeOf and typeInfo is needed. Works until the compiler changes, happy for now!
        const fieldType = @TypeOf(@field(fileType, field.name));
        const fieldTypeInfo = @typeInfo(fieldType);

        switch (fieldTypeInfo) {
            .Fn => {
                if (fieldTypeInfo.Fn.params.len != 1 or fieldTypeInfo.Fn.params[0].type != parameterType) continue;

                if (fieldTypeInfo.Fn.return_type) |fnReturnType| {
                    if (fnReturnType == returnType) {
                        funcs[i] = @field(fileType, field.name);
                        i += 1;
                    }
                }
            },
            else => {},
        }
    }

    return funcs[0..i];
}
