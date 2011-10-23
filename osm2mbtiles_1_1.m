//
// osm2mbtiles_1_2.m was created from
// map2sqlite.m which is copyrighted as follows:
//
// Copyright (c) 2009, Frank Schroeder, SharpMind GbR
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

//
// osm2mbtiles_1_1 - import utility for the RMDBTileSource
//
// osm2mbtiles_1_1 creates a sqlite database compliant with the mbtiles 1.1 
//  specification and usable by RMDBTileSource of the route-me project.
// 
// It supports importing of OpenStreetmap tile structure
// 
//         <zoom>/<col>/<row>.png
//
//     zoom, col, row: decimal values
// NOTE: the mbtile 1.1 spec stores the tiles in TMS format, not xyz format!
// NOTE^2: The mbtile spec has in their roadmap to switch to the OSM xyz format!
//
// The following tables are created and populated.
//
// table "metadata" - contains the map meta data as name/value pairs
//
//  SQL: CREATE TABLE metadata (name text, value text);
//
//    As per the mbtile spec, the metadata table must at least contain 
//      the following values.
//
//      name: The plain-english name of the tileset.
//      type: overlay or baselayer
//      version: The version of the tileset, as a plain number.
//      description: A description of the layer as plain text.
// 
//
//  table "tiles" - contains the tile images
//
//  SQL: CREATE TABLE tiles (   zoom_level integer, 
//                              tile_column integer, 
//                              tile_row integer, 
//                              tile_data blob);
//
//
//  Content
//      The tiles table contains tiles and the values used to locate them. The 
//      zoom_level, tile_column, and tile_row columns follow the Tile Map Service 
//      Specification in their construction, but in a restricted form:
//
//      The global-mercator (aka Spherical Mercator) profile is assumed
//      The blob column contains raw image data in binary.
//
//      Formats supported:
//
//          png
//          jpg
//

#import <Foundation/Foundation.h>
#import "FMDatabase.h"
#import "FMDatabaseAdditions.h"

#define FMDBQuickCheck(SomeBool)	{ if (!(SomeBool)) { NSLog(@"Failure on line %d", __LINE__); return 123; } }
#define FMDBErrorCheck(db)			{ if ([db hadError]) { NSLog(@"DB error %d on line %d: %@", [db lastErrorCode], __LINE__, [db lastErrorMessage]); } }
#define NSStringFromPoint(p)		([NSString stringWithFormat:@"{x=%1.6f,y=%1.6f}", (p).x, (p).y])
#define NSStringFromSize(s)			([NSString stringWithFormat:@"{w=%1.1f,h=%1.1f}", (s).width, (s).height])
#define NSStringFromRect(r)			([NSString stringWithFormat:@"{x=%1.1f,y=%1.1f,w=%1.1f,h=%1.1f}", (r).origin.x, (r).origin.y, (r).size.width, (r).size.height])

// version of this program
#define kVersion @"1.0"

// mandatory preference keys
#define kMinZoomKey @"map.minZoom"
#define kMaxZoomKey @"map.maxZoom"
#define kTileSideLengthKey @"map.tileSideLength"

// optional preference keys for the coverage area
#define kCoverageTopLeftLatitudeKey @"map.coverage.topLeft.latitude"
#define kCoverageTopLeftLongitudeKey @"map.coverage.topLeft.longitude"
#define kCoverageBottomRightLatitudeKey @"map.coverage.bottomRight.latitude"
#define kCoverageBottomRightLongitudeKey @"map.coverage.bottomRight.longitude"
#define kCoverageCenterLatitudeKey @"map.coverage.center.latitude"
#define kCoverageCenterLongitudeKey @"map.coverage.center.longitude"

// optional preference keys for the attribution
#define kShortNameKey @"map.shortName"
#define kLongDescriptionKey @"map.longDescription"
#define kShortAttributionKey @"map.shortAttribution"
#define kLongAttributionKey @"map.longAttribution"



/* ----------------------------------------------------------------------
 * Helper functions
 */

/*
 * Calculates the top left coordinate of a tile.
 * (assumes OpenStreetmap tiles)
 */
CGPoint pointForTile(int row, int col, int zoom) {
	float lon = col / pow(2.0, zoom) * 360.0 - 180;	
	float n = M_PI - 2.0 * M_PI * row / pow(2.0, zoom);
	float lat = 180.0 / M_PI * atan(0.5 * (exp(n) - exp(-n)));
	
	return CGPointMake(lon, lat);
}

/*
 * Prints usage information.
 */
void printUsage() {
	NSLog(@"Usage: osm2mbtiles -db <db file> [-mapdir <map directory>]");
}

/*
 * Converts a hexadecimal string into an integer value.
 */
NSUInteger scanHexInt(NSString* s) {
	NSUInteger value;
	
	NSScanner* scanner = [NSScanner scannerWithString:s];
	[scanner setCharactersToBeSkipped:[NSCharacterSet characterSetWithCharactersInString:@"LRC"]];
	if ([scanner scanHexInt:&value]) {
		return value;
	} else {
		NSLog(@"not a hex int %@", s);
		return -1;
	}
}




/* ----------------------------------------------------------------------
 * Database functions
 */

/*
 * Creates an empty sqlite database
 */
FMDatabase* createDB(NSString* dbFile) {
	// delete the old db file
	[[NSFileManager defaultManager] removeFileAtPath:dbFile handler:nil];
	
	FMDatabase* db = [FMDatabase databaseWithPath:dbFile];
	NSLog(@"Creating %@", dbFile);
	if (![db open]) {
		NSLog(@"Could not create %@.", dbFile);
		return nil;
	}
	
	return db;
}

/*
 * Executes a query with error check and returns the result set.
 */
FMResultSet* executeQuery(FMDatabase* db, NSString* sql, ...) {
	va_list args;
	va_start(args, sql);
	FMResultSet* rs = [db executeQuery:sql arguments:args];
	va_end(args);
	FMDBErrorCheck(db);
	
	return rs;
}

/*
 * Executes an update query with error check.
 */
void executeUpdate(FMDatabase* db, NSString* sql, ...) {
	va_list args;
	va_start(args, sql);
	[db executeUpdate:sql arguments:args];
	va_end(args);
	FMDBErrorCheck(db);
}

/* ----------------------------------------------------------------------
 * Preference functions
 */

void addStringAsMeta(FMDatabase* db, NSString* name, NSString* value) {
	executeUpdate(db, @"insert into preferences (name, value) values (?,?)", name, value);
}

void addFloatAsMeta(FMDatabase* db, NSString* name, float value) {
	addStringAsMeta(db, name, [NSString stringWithFormat:@"%f", value]);
}

void addIntAsMeta(FMDatabase* db, NSString* name, int value) {
	addStringAsMeta(db, name, [NSString stringWithFormat:@"%d", value]);
}

void createMetadata(FMDatabase* db) {
    // NOTE: Indexes are NOT part of the spec
	executeUpdate(db, @"CREATE TABLE metadata (name text primary key, value text)");
}

/* ----------------------------------------------------------------------
 * Main functions
 */

/*
 * Creates the "tiles" table and imports a given directory structure
 * into the table.
 */
void createMapDB(FMDatabase* db, NSString* mapDir) {
	NSFileManager* fileManager = [NSFileManager defaultManager];
	
	// Create the tiles table NOTE: Indexes are NOT part of the spec
	executeUpdate(db, @"CREATE TABLE tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob, PRIMARY KEY (zoom_level, tile_column, tile_row))");
	
	// OpenStreetMap tile structure
	// 
	//   <zoom>/<col>/<row>.png
	//
	// zoom, col, row: decimal values
	//
	//
	//
	int minZoom = INT_MAX;
	int maxZoom = INT_MIN;
    int nCounter = 100;
	NSLog(@"Importing map tiles at %@", mapDir);
	for (NSString* f in [fileManager subpathsAtPath:mapDir]) {
		if ([[[f pathExtension] lowercaseString] isEqualToString:@"png"]) {
			NSArray* comp = [f componentsSeparatedByString:@"/"];
			NSUInteger zoom, row, col, osmRow, osmCol;
			
            zoom = [[comp objectAtIndex:0] intValue];
			osmCol = [[comp objectAtIndex:1] intValue];
			osmRow = [[[comp objectAtIndex:2] stringByDeletingPathExtension] intValue];
			
			// update min and max zoom
			minZoom = fmin(minZoom, zoom);
			maxZoom = fmax(maxZoom, zoom);
            
            // rcarver convert OSM row, col to TMS row, col.
            // As of v1.1 of mbtiles spec, the tiles are stored in TMS format - this will change in future revs of mbtiles
			row = pow(2,zoom)-osmRow-1;
            col = osmCol;
            
            if( nCounter-- > 0 ){
                int nZoomNumber = pow(2,zoom);
                NSLog(@"Zoom Number %d, osmRow: %d, end row: %d",nZoomNumber, osmRow, row );
            }
            
            // load the image data from the file
			NSData* image = [[NSData alloc] initWithContentsOfFile:[NSString stringWithFormat:@"%@/%@", mapDir, f]];
			if (image) {
				executeUpdate(db, @"insert into tiles (zoom_level, tile_column, tile_row, tile_data) values (?, ?, ?, ?)", 
							  [NSNumber numberWithInt:zoom], 
							  [NSNumber numberWithInt:col], 
							  [NSNumber numberWithInt:row], 
							  image);
				[image release];
			} else {
				NSLog(@"Could not read %@", f);
			}
		}
	}
	
}

/*
 * Displays some statistics about the tiles in the imported database.
 */
void showMapDBStats(FMDatabase* db, NSString* dbFile, NSString* mapDir) {
	NSFileManager* fileManager = [NSFileManager defaultManager];
	
	// print some map statistics
	// print some map statistics
	FMResultSet* rs = executeQuery(db, @"select count(*) count, min(zoom_level) min_zoom, max(zoom_level) max_zoom from tiles");
	if ([rs next]) {
		int count = [rs intForColumn:@"count"];
		int minZoom = [rs intForColumn:@"min_zoom"];
		int maxZoom = [rs intForColumn:@"max_zoom"];
		unsigned long long fileSize = [[[fileManager fileAttributesAtPath:dbFile traverseLink:YES] objectForKey:NSFileSize] unsignedLongLongValue];
		
		NSLog(@"\n");
		NSLog(@"Map statistics");
		NSLog(@"--------------");
		NSLog(@"map db:            %@", dbFile);
		NSLog(@"file size:         %qi bytes", fileSize);
		NSLog(@"tile directory:    %@", mapDir);
		NSLog(@"number of tiles:   %d", count);
		NSLog(@"zoom levels:       %d - %d", minZoom, maxZoom);
	}
	[rs close];
	
}

/*
 * main method
 */
int main (int argc, const char * argv[]) {
	NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
	NSFileManager* fileManager = [NSFileManager defaultManager];

	// print the version
    NSLog(@"osm2mbtiles %@\n - generating for mbtile v1.1", kVersion);
    
	// get the command line args
	NSUserDefaults *args = [NSUserDefaults standardUserDefaults];
	
	// command line args
	NSString* dbFile = [args stringForKey:@"db"];
	NSString* mapDir = [args stringForKey:@"mapdir"];

	// check command line args
	if (dbFile == nil) {
		printUsage();
		[pool release];
		return 1;
	}
	
	// check that the map directory exists
	if (mapDir != nil) {
		BOOL isDir;
		if (![fileManager fileExistsAtPath:mapDir isDirectory:&isDir] && isDir) {
			NSLog(@"Map directory does not exist: %@", mapDir);
			[pool release];
			return 1;
		}
	}
	
	// delete the old db
	[fileManager removeFileAtPath:dbFile handler:nil];
	
	// create the db
	FMDatabase* db = createDB(dbFile);
	if (db == nil) {
		NSLog(@"Error creating database %@", dbFile);
		[pool release];
		return 1;
	}
	
	// cache the statements as we're using them a lot
	db.shouldCacheStatements = YES;
	
	// create the preferences table
	createMetadata(db);
	
	// import the map
	if (mapDir != nil) {
		createMapDB(db, mapDir);
		showMapDBStats(db, dbFile, mapDir);
	}

	// cleanup
	[db close];
    [pool release];
    return 0;
}
