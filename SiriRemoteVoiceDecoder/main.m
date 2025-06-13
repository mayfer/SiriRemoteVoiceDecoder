//
//  main.m
//  SiriRemoteVoiceDecoder
//
//  Created by Jack on 12/1/20.  Patched June 2025 for the aluminium Siri Remote.
//

#import <Foundation/Foundation.h>
#import "OKDecoder.h"

@interface NSData (Hexadecimal)
- (NSData *)initWithHexadecimalString:(NSString *)string;
+ (NSData *)dataWithHexadecimalString:(NSString *)string;
@end

unsigned char _hexCharToInteger(unsigned char hexChar) {
    if (hexChar >= '0' && hexChar <= '9') {
        return (hexChar - '0') & 0xF;
    } else {
        return ((hexChar - 'A') + 10) & 0xF;
    }
}

@implementation NSData (Hexadecimal)
- (id)initWithHexadecimalString:(NSString *)string {
    const char *hexstring = [string UTF8String];
    int dataLength        = (int)[string length] / 2;
    unsigned char *data   = malloc(dataLength);
    if (data == nil) {
        return nil;
    }
    for (int i = 0; i < dataLength; i++) {
        unsigned char firstByte  = hexstring[2 * i];
        unsigned char secondByte = hexstring[2 * i + 1];
        unsigned char byte       = (_hexCharToInteger(firstByte) << 4) + _hexCharToInteger(secondByte);
        data[i]                  = byte;
    }
    self = [self initWithBytes:data length:dataLength];
    free(data);
    return self;
}

+ (NSData *)dataWithHexadecimalString:(NSString *)string {
    return [[self alloc] initWithHexadecimalString:string];
}
@end

@implementation NSString (TrimmingAdditions)
- (NSString *)stringByTrimmingLeadingCharactersInSet:(NSCharacterSet *)characterSet {
    NSUInteger location = 0;
    NSUInteger length   = [self length];
    unichar     buffer[length];
    [self getCharacters:buffer];

    for (; location < length; location++) {
        if (![characterSet characterIsMember:buffer[location]]) {
            break;
        }
    }
    return [self substringWithRange:NSMakeRange(location, length - location)];
}

- (NSString *)stringByTrimmingTrailingCharactersInSet:(NSCharacterSet *)characterSet {
    NSUInteger length = [self length];
    unichar     buffer[length];
    [self getCharacters:buffer];

    while (length > 0) {
        if (![characterSet characterIsMember:buffer[length - 1]]) {
            break;
        }
        length--;
    }
    return [self substringWithRange:NSMakeRange(0, length)];
}
@end

static inline void c_print_ln(NSString *s) { printf("%s\n", [s UTF8String]); }

static NSString *read_till(char terminator) {
    NSMutableString *ret = [NSMutableString string];
    char              r  = getchar();
    while (r != terminator && r != '\0') {
        [ret appendFormat:@"%c", r];
        r = getchar();
    }
    return ret;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        /* ------------------------------------------------------------------ */
        NSString *siriRemoteMACAddress = @"";
        if (argc > 1) {
            siriRemoteMACAddress = [NSString stringWithCString:argv[1] encoding:NSUTF8StringEncoding];
        }

        BOOL voiceStarted = NO;

        const int   index_data = 54;                // offset where packet-logger puts the bytes
        __block int index_b8   = 48;                // aluminium remote: "B8" at byte 16 → 16*3 = 48
                                                   // (old remote used 54)
        NSString *inputLine  = @"";
        NSString *inputData  = @"";
        NSMutableString *frames = [NSMutableString string];
        NSMutableString *frame  = [NSMutableString string];

        /* ------------------------------------------------------------------ */
        OKDecoder *opusDecoder = [[OKDecoder alloc] initWithSampleRate:16000 numberOfChannels:1];
        NSError   *error       = nil;
        if (![opusDecoder setupDecoderWithError:&error]) {
            NSLog(@"Error setting up opus decoder: %@", error);
            return 1;
        }

        /* ----------------------- live packet-logger loop ------------------- */
        while (1) {
            inputLine = read_till('\n');
            if (([siriRemoteMACAddress length] == 0 ||
                 [inputLine containsString:siriRemoteMACAddress] ||
                 [inputLine containsString:@"00:00:00:00:00:00"]) &&
                [inputLine containsString:@"RECV"]) {

                inputData = [[inputLine substringFromIndex:index_data]
                    stringByTrimmingTrailingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                c_print_ln([NSString stringWithFormat:@"Reading in: %@", inputData]);

                /* -------- voice-start / voice-end detection (new remote only) ---- */
                if ([inputData hasSuffix:@"1B 39 00 20 00"]) {
                    printf("Voice started...\n");
                    frames.string = @"";
                    frame.string  = @"";
                    voiceStarted  = YES;
                    continue;
                }
                if ([inputData hasSuffix:@"1B 39 00 00 00"]) {
                    printf("Voice ended...\n");
                    voiceStarted = NO;

                    /* -------------------- decode all collected frames ------------- */
                    NSMutableData *decoded = [NSMutableData data];
                    for (NSString *oneFrame in [frames componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                        if ([oneFrame length] < 6) continue;
                        NSData *frameData   = [NSData dataWithHexadecimalString:[oneFrame stringByReplacingOccurrencesOfString:@" " withString:@""]];
                        if ([frameData length] == 0) continue;
                        int8_t packetLen = *((int8_t *)frameData.bytes);
                        if ([frameData length] <= packetLen) continue;
                        NSData *packetData = [frameData subdataWithRange:NSMakeRange(1, packetLen)];
                        [opusDecoder decodePacket:packetData completionBlock:^(NSData *pcm, NSUInteger _, NSError *err) {
                            if (!err) [decoded appendData:pcm];
                        }];
                    }
                    [NSThread sleepForTimeInterval:0.5];          // let decoder finish

                    /* -------------------- write WAV ------------------------------ */
                    FILE *f = fopen("decoded.wav", "w");
                    if (!f) { perror("decoded.wav"); break; }
                    int dataSz     = (int)[decoded length];
                    int totalSz    = 36 + dataSz;
                    uint32_t fmtChunk  = 16;          // 4-byte, little-endian
                    uint16_t audioFmt  = 1;           // PCM
                    uint16_t channels  = 1;
                    uint32_t sampleRate = 16000;
                    uint16_t bitsPer    = 16;
                    uint32_t byteRate   = sampleRate * channels * bitsPer / 8;
                    uint16_t blkAlign   = channels * bitsPer / 8;
                    
                    fwrite("RIFF", 1, 4, f); fwrite(&totalSz, 4, 1, f);
                    fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmtChunk, 4, 1, f);
                    fwrite(&audioFmt, 2, 1, f); fwrite(&channels, 2, 1, f);
                    fwrite(&sampleRate, 4, 1, f); fwrite(&byteRate, 4, 1, f);
                    fwrite(&blkAlign, 2, 1, f); fwrite(&bitsPer, 2, 1, f);
                    fwrite("data", 1, 4, f); fwrite(&dataSz, 4, 1, f);
                    fwrite(decoded.bytes, 1, dataSz, f);
                    fclose(f);
                    printf("Saved decoded.wav (%d bytes)\n", dataSz + 44);
                    break;          // stop after one utterance
                }

                /* -------------------------- collect Opus frames ------------------ */
                if (voiceStarted) {
                    BOOL isHeader = ([inputData hasPrefix:@"5E 20"] || [inputData hasPrefix:@"40 20"]);
                    if (isHeader && [inputData length] > index_b8 + 1 &&
                        [[inputData substringWithRange:NSMakeRange(index_b8, 2)] isEqualToString:@"B8"]) {
                        /* flush previous frame */
                        if ([frame length]) {
                            if ([frames length]) [frames appendFormat:@"\n%@", frame];
                            else                 frames.string = frame;
                        }
                        /* start new frame (include length byte before B8) */
                        frame = [[inputData substringFromIndex:index_b8 - 3] mutableCopy];
                    } else {
                        /* continuation line: skip first 3 bytes (12 chars) */
                        if ([inputData length] > 12)
                            [frame appendFormat:@" %@", [inputData substringFromIndex:12]];
                    }
                }
            }
        }
    }
    return 0;
}
