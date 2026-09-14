import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.File;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;

public class ExportFunctions extends GhidraScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        File dir = new File(args[0]);
        dir.mkdirs();
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        int count = 0;
        for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
            long a = f.getEntryPoint().getOffset();
            if (a > 0x425000 && a < 0x468000) continue;
            File out = new File(dir, String.format("%08x.c", a));
            if (out.exists()) continue;
            DecompileResults r = decompiler.decompileFunction(f, 15, monitor);
            if (r.decompileCompleted()) {
                Files.writeString(out.toPath(), r.getDecompiledFunction().getC(), StandardCharsets.UTF_8);
                count++;
            }
        }
        decompiler.dispose();
        println("Exported " + count + " functions");
    }
}
