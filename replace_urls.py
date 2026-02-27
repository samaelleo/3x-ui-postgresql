import os

directory = r"c:\Users\Samael\PycharmProjects\3x-ui-postgresql"

extensions = [".sh", ".md", ".html", ".go"]
replacements = {
    "samaelleo/3x-ui-main": "samaelleo/3x-ui-postgresql",
    "MHSanaei/3x-ui": "samaelleo/3x-ui-postgresql"
}

for root, dirs, files in os.walk(directory):
    if ".git" in root or ".idea" in root:
        continue
    for file in files:
        if file.endswith(tuple(extensions)):
            filepath = os.path.join(root, file)
            try:
                with open(filepath, "r", encoding="utf-8") as f:
                    content = f.read()
                
                changed = False
                for old, new in replacements.items():
                    if old in content:
                        content = content.replace(old, new)
                        changed = True
                
                if changed:
                    with open(filepath, "w", encoding="utf-8", newline="") as f:
                        f.write(content)
                    print(f"Updated {filepath}")
            except Exception as e:
                print(f"Error reading {filepath}: {e}")
