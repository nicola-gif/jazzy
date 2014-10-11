//
//  main.m
//  SourceKitten
//
//  Created by JP Simard on 7/11/14.
//  Copyright (c) 2014 Realm. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <XPCKit/XPCKit.h>
#import "sourcekitd.h"
#import "SKTCompilerArgumentTransformer.h"

NSString * const CompilerArgumentTransformerName = @"CompilerArgumentTransformer";

NSArray *name_offsets_and_lengths_in_dictionary(NSDictionary *dictionary) {
    NSMutableArray *nameOffsetsAndLengths = [NSMutableArray array];
    NSArray *keys = [dictionary allKeys];
    if ([keys containsObject:@"key.namelength"] && [keys containsObject:@"key.nameoffset"]) {
        [nameOffsetsAndLengths addObject:@{@"key.namelength": dictionary[@"key.namelength"],
                                           @"key.nameoffset": dictionary[@"key.nameoffset"]}];
    }
    if ([keys containsObject:@"key.substructure"]) {
        for (NSDictionary *substructure in dictionary[@"key.substructure"]) {
            [nameOffsetsAndLengths addObjectsFromArray:name_offsets_and_lengths_in_dictionary(substructure)];
        }
    }
    return [nameOffsetsAndLengths copy];
}

int error(const char *message) {
    printf("Error: %s\n\n", message);
    return 1;
}

int docs_for_swift_compiler_args(NSString *compilerArgsString) {
    sourcekitd_initialize();

    NSValueTransformer *valueTransformer = [NSValueTransformer valueTransformerForName:CompilerArgumentTransformerName];
    NSArray *arguments = [valueTransformer transformedValue:compilerArgsString];
    xpc_object_t compilerargs = [arguments newXPCObject];
    
    NSArray *swiftFiles = [arguments filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self endswith '.swift'"]];
    
    xpc_object_t openRequest = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(openRequest, "key.request", sourcekitd_uid_get_from_cstr("source.request.editor.open"));
    xpc_dictionary_set_string(openRequest, "key.name", "");
    
    for (NSString *file in swiftFiles) {
        xpc_dictionary_set_string(openRequest, "key.sourcefile", file.UTF8String);
        
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfXPCObject:sourcekitd_send_request_sync(openRequest)];
        NSArray *nameOffsetsAndLengths = name_offsets_and_lengths_in_dictionary(dict);
        
        NSMutableSet *seenDocs = [NSMutableSet set];
        
        xpc_object_t cursorInfoRequest = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(cursorInfoRequest, "key.request", sourcekitd_uid_get_from_cstr("source.request.cursorinfo"));
        xpc_dictionary_set_value(cursorInfoRequest, "key.compilerargs", compilerargs);
        xpc_dictionary_set_string(cursorInfoRequest, "key.sourcefile", file.UTF8String);
        
        for (NSDictionary *entity in nameOffsetsAndLengths) {
            NSUInteger nameOffset = [entity[@"key.nameoffset"] unsignedIntegerValue];
            NSUInteger nameLength = [entity[@"key.namelength"] unsignedIntegerValue];
            for (NSUInteger cursor = nameOffset; cursor < nameLength + nameOffset; cursor++) {
                xpc_dictionary_set_int64(cursorInfoRequest, "key.offset", cursor);
                
                xpc_object_t result = sourcekitd_send_request_sync(cursorInfoRequest);
                if (!sourcekitd_response_is_error(result)) {
                    const char *xml = xpc_dictionary_get_string(result, "key.doc.full_as_xml");
                    if (xml != nil) {
                        NSString *xmlString = @(xml);
                        NSNumber *xmlHash = @([xmlString hash]);
                        if (![seenDocs containsObject:xmlHash] &&
                            [xmlString rangeOfString:file].location != NSNotFound) {
                            printf("%s\n", xml);
                            [seenDocs addObject:xmlHash];
                        }
                    }
                }
            }
        }
    }
    
    return 1;
}

void clean_project() {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/xcodebuild";
    task.arguments = @[@"clean"];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    
    [task launch];
    [task waitUntilExit];
}

void initialize_value_transformer() {
    [NSValueTransformer setValueTransformer:[[SKTCompilerArgumentTransformer alloc] init] forName:CompilerArgumentTransformerName];
}

int main(int argc, const char * argv[]) {
    NSPipe *pipe = [NSPipe pipe];
    NSFileHandle *file = pipe.fileHandleForReading;

    clean_project();
    
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/xcodebuild";
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    [task launch];

    NSData *data = [file readDataToEndOfFile];
    [file closeFile];

    initialize_value_transformer();

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"/Applications/Xcode[^/]*\\.app/Contents/Developer/Toolchains/XcodeDefault\\.xctoolchain/usr/bin/swiftc.*" options:0 error:nil];
    NSTextCheckingResult *regexMatch = [regex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];
    if (regexMatch) {
        return docs_for_swift_compiler_args([output substringWithRange:regexMatch.range]);
    } else {
        error("Path not found\n");
    }
    return 0;
}
