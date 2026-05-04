import re

with open('Trawl.xcodeproj/project.pbxproj', 'r') as f:
    content = f.read()

new_files = [
    "ArrStack/Components/ArrQualityProfilePicker.swift",
    "ArrStack/Components/ArrRootFolderPicker.swift",
    "ArrStack/Components/ArrAddItemSearchBar.swift",
    "ArrStack/Components/ArrMonitorBadge.swift",
    "ArrStack/Components/ArrMonitoredToggle.swift",
    "Views/FormComponents/AllowUntrustedTLSToggle.swift",
    "Views/FormComponents/CredentialsSection.swift",
    "Views/FormComponents/ModalFormStyle.swift",
    "Views/FormComponents/ServerURLField.swift",
    "Views/FormComponents/ValidationErrorSection.swift",
    "ArrStack/Detail/ArrItemDetailView.swift",
    "ArrStack/Detail/ArrDetailHeaderView.swift"
]

def insert_exceptions(target_block, files):
    # Find the membershipExceptions = ( ... ); block inside the target block
    match = re.search(r'membershipExceptions\s*=\s*\((.*?)\);', target_block, re.DOTALL)
    if not match: return target_block
    
    existing = match.group(1)
    lines = [line.strip() for line in existing.split('\n') if line.strip()]
    
    for f in files:
        if f + "," not in lines and '"' + f + '",' not in lines:
            lines.append(f + ",")
            
    lines.sort()
    
    new_exceptions = "\n\t\t\t\t".join(lines)
    if new_exceptions:
        new_exceptions = "\n\t\t\t\t" + new_exceptions + "\n\t\t\t"
        
    return target_block[:match.start()] + "membershipExceptions = (" + new_exceptions + ");" + target_block[match.end():]

# Find the PBXFileSystemSynchronizedBuildFileExceptionSet section
section_start = content.find('/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */')
section_end = content.find('/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */')

if section_start != -1 and section_end != -1:
    section_content = content[section_start:section_end]
    
    # We want to update CCB00000CCB00000CCB00000 (TrawlShare) and FFB00000FFB00000FFB00000 (TrawlWidgets)
    
    # Split by blocks
    blocks = re.split(r'(?=\t\t[A-F0-9]{24} /\* Exceptions)', section_content)
    
    for i in range(len(blocks)):
        if "TrawlShare" in blocks[i] or "TrawlWidgets" in blocks[i]:
            blocks[i] = insert_exceptions(blocks[i], new_files)
            
    new_section_content = "".join(blocks)
    content = content[:section_start] + new_section_content + content[section_end:]
    
    with open('Trawl.xcodeproj/project.pbxproj', 'w') as f:
        f.write(content)
    print("Successfully updated project.pbxproj")
else:
    print("Could not find section")
