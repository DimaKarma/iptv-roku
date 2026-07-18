' Task for reading and parsing the configuration file
sub init()
    m.top.functionName = "loadConfig"
end sub

sub loadConfig()
    configStr = ReadAsciiFile("pkg:/config.json")
    if configStr = ""
        m.top.error = "File not found or empty"
        return
    end if
    
    configObj = ParseJson(configStr)
    if configObj = invalid
        m.top.error = "Invalid JSON"
        return
    end if
    
    m.top.config = configObj
end sub
