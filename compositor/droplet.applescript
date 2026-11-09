-- "Negatieven naar Compositor": sleep een map met scans (of losse DNG's) op dit icoon.
-- install-droplet.sh vult het pad naar neg2comp.mjs in en maakt hier een app van.

property scriptPath : "__SCRIPT__"
property appTitle : "Negatieven naar Compositor"

on run
	display dialog "Sleep een map met scans, of losse DNG's, op dit icoon in je Dock." buttons {"OK"} default button 1 with title appTitle
end run

on open droppedItems
	set choice to choose from list {"Kleurnegatief", "Zwart-wit negatief", "Al positief (alleen bijstellen)"} with title appTitle with prompt "Wat voor scans zijn dit?" default items {"Kleurnegatief"}
	if choice is false then return
	set scanType to item 1 of choice

	set opts to "--rol"
	if scanType is "Zwart-wit negatief" then set opts to opts & " --zw"
	if scanType is "Al positief (alleen bijstellen)" then set opts to opts & " --positief"

	set args to ""
	repeat with anItem in droppedItems
		set args to args & " " & quoted form of (POSIX path of anItem)
	end repeat

	display notification "Bezig met omzetten. Dit duurt een paar seconden per scan." with title appTitle
	try
		set output to do shell script "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; node " & quoted form of scriptPath & " " & opts & args & " 2>&1"
	on error errText
		display dialog "Er ging iets mis:" & return & return & errText buttons {"OK"} default button 1 with icon stop with title appTitle
		return
	end try

	if output contains "geen oranje masker" then
		display dialog "Sommige scans lijken al positief te zijn. Ziet het resultaat eruit als een negatief? Sleep ze dan opnieuw en kies \"Al positief\"." buttons {"OK"} default button 1 with title appTitle
	end if

	-- Toon de map met de nieuwe .comp-bestanden
	set firstPath to POSIX path of (item 1 of droppedItems)
	do shell script "p=" & quoted form of firstPath & "; if [ -d \"$p\" ]; then open \"$p\"; else open \"$(dirname \"$p\")\"; fi"
	display notification "Klaar. Dubbelklik een .comp-bestand om het in Compositor te openen." with title appTitle
end open
