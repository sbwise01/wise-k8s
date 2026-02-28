#!/usr/bin/env python3

import glob
import hashlib
import os

dir = "/plexmedia/staging/*"
outputFileName = "/tmp/movie_hashes.csv"


def md5(fname):
    hash_md5 = hashlib.md5()
    with open(fname, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()

def main():
    hashes = {}
    csvFile = open(outputFileName, "w")
    files = sorted(glob.glob(dir))
    for file in files:
        baseName = os.path.basename(file)
        print(f"Creating hash for:  {baseName}")
        hash = md5(file)
        hashes[hash] = baseName
        csvFile.write("%s,\"%s\"\n" % (hash, baseName) )

    csvFile.close()
    print(hashes)

if __name__== "__main__":
    main()
