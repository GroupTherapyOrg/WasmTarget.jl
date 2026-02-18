import binaryen from "binaryen";
import fs from "fs";

// Check what's available on the binaryen object
const keys = Object.keys(binaryen).filter(k => !k.startsWith("_"));
console.log("Top-level keys count:", keys.length);
console.log("Keys sample:", keys.slice(0, 50).join(", "));
console.log("");
console.log("features:", binaryen.features);
console.log("Features:", binaryen.Features);
console.log("version:", binaryen.version);
console.log("readBinary:", typeof binaryen.readBinary);
console.log("parseText:", typeof binaryen.parseText);
console.log("Module:", typeof binaryen.Module);
