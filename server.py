# https://docs.python.org/3/library/http.server.html
from http.server import HTTPServer, SimpleHTTPRequestHandler
from enum import Enum
from os import getcwd
from pathlib import Path
from threading import Thread

# OBS scripting library -> https://obsproject.com/docs/scripting.html
# Settings documentation -> https://obsproject.com/docs/reference-settings.html
if __name__ != "__main__":
	import obspython as obs

# Enumerate UI elements
class Property(Enum):
	DIR = 1
	PORT = 2
	APIID = 3
	# APISECRET = 4
	STATUS = 5
	CONTROL = 6
	RESTART = 7

# Path to directory containing script
# (Defaults here assuming the average user wants their server directory near the same folder)
scriptDir = Path(__file__).absolute().parent

# UI element string data
UIElements = {
	Property.DIR : {
		"ID" : "datadir",
		"Type" : "str",
		"Desc" : "Root",
		"Default" : str(scriptDir),
		"Tooltip" : "Specify the root directory inside which the server will honor requests."	\
				+ "\n'http://localhost' will respond with the file '<root dir>/index.html'"		\
				+ "\nSelection must be a valid directory with read permissions."
	},

	Property.PORT : {
		"ID" : "port",
		"Type" : "int",
		"Desc" : "Port",
		"Default" : 1085,
		"Tooltip" : "Specify the port that the server will run on."								\
				+ "\n(Used in your browser source URL, i.e: 'http://localhost:1085')"			\
				+ "\nPort must be a valid, unprotected port number [1024 - 65535]"
	},

	Property.APIID : {
		"ID" : "clientid",
		"Type" : "str",
		"Desc" : "ID",
		"Default" : "",
		"Tooltip" : "Twitch API Client ID" 														\
				+ "\nAvailable once an application is registered through 'dev.twitch.tv'"
	},

	Property.STATUS : {
		"ID" : "status",
		"Type" : "none",		# Property holds no data (setting)
		"Desc" : "STATUS",		# Pending update from updateUI()
		"Tooltip" : ""
	},

	Property.CONTROL : {
		"ID" : "control",
		"Type" : "none",		# Property holds no data (setting)
		"Desc" : "CONTROL",		# Pending update from updateUI()
		"Tooltip" : "Start or stop the web server."												\
				+ "\nSaves one the effort of unloading the script."
	},

	Property.RESTART : {
		"ID" : "restart",
		"Type" : "bool",
		"Desc" : "Automatically start server",
		"Default" : False,
		"Tooltip" : "Automatically begins the alert server when OBS starts."
	}
}

# -- UI Element management functions --
# TODO add remaining obs types

# Return setting value of a UI element
def getSetting(settings, property):
	fun = None

	elementType = UIElements[property]["Type"]
	match elementType:
		case "int": fun = obs.obs_data_get_int
		case "bool": fun = obs.obs_data_get_bool
		case "str": fun = obs.obs_data_get_string
	
	if fun is None: return None
	return fun(settings, UIElements[property]["ID"])

# Set default setting value for a UI element
def setSettingDefault(settings, property):
	fun = None

	elementType = UIElements[property]["Type"]
	match elementType:
		case "int": fun = obs.obs_data_set_default_int
		case "bool": fun = obs.obs_data_set_default_bool
		case "str": fun = obs.obs_data_set_default_string
	
	if fun is None: return
	fun(settings, UIElements[property]["ID"], UIElements[property]["Default"])

# --------------------------------------------------------------------------- #

class ScriptManager:
	def __init__(self, settings):
		# Script object references
		self.settings = settings
		self.properties = None

		# Server references
		self.alertServer = None
		self.serverThread = None
		self.running = False		# Is the server running (previously status from getStatus)

		# Parsed from the obs_data_t settings type
		self.serverSettings = {
			Property.DIR : UIElements[Property.DIR]["Default"],
			Property.PORT : UIElements[Property.PORT]["Default"],
			Property.APIID : UIElements[Property.APIID]["Default"],
			Property.RESTART : UIElements[Property.RESTART]["Default"]
		}

		# Populate values
		self.updateServerSettings(settings)

		# Start server if auto restart is enabled
		if self.serverSettings[Property.RESTART]:
			self.startServer()

	# -- Logging aliases --
	def log(self, message):
		obs.script_log(obs.LOG_INFO, message)
	
	def warn(self, message):
		obs.script_log(obs.LOG_WARNING, message)

	# Print out an OBS obs_data_t settings type
	def printSettings(self, settings):
		json_str = obs.obs_data_get_json(settings)
		obs.script_log(obs.LOG_DEBUG, json_str)

	# -- Callbacks (class functions) --
	def controlClickedCallback(properties, property):
		if SCRIPT.running: SCRIPT.stopServer()
		else: SCRIPT.startServer()

		# ...If I wanted to move auto-restart back to a "secret" variable UwU
		# obs.obs_data_set_bool(settingsRef, Property.RESTART.value, status)

		return True

	def debugClickedCallback(properties, property):
		ScriptManager.log(None, "Debug clicked callback")

		# Properties passed through callback function param
		button = obs.obs_properties_get(properties, UIElements[Property.CONTROL]["ID"])

		if button is None: ScriptManager.warn(None, "Control button object not found!")
		else: obs.obs_property_set_description(button, "balls")

		return True

	# Dummy function to ensure the UI updates when the server is stopped via setting change
	# TODO I'm not convinced that this is a guaranteed fix
	# I'm honestly surprised it seems to update, when I'd anticipate it would happen before changing the state of the server
	def criticalPropertyModified(properties, property, settings = None):
		# if settings is None:
		# 	ScriptManager.log(None, "Settings is None")
		# 	return
		# ScriptManager.log(None, "Property modified called!")
		return True

	# -- UI management functions --
	# Specify the UI elements
	def setProperties(self, properties):
		# Server root directory setting (critical)
		data = UIElements[Property.DIR]
		prop = obs.obs_properties_add_path(properties, data["ID"], data["Desc"], obs.OBS_PATH_DIRECTORY, None, data["Default"])
		obs.obs_property_set_long_description(prop, data["Tooltip"])
		obs.obs_property_set_modified_callback(prop, ScriptManager.criticalPropertyModified)

		# Server port setting (critical)
		data = UIElements[Property.PORT]
		prop = obs.obs_properties_add_int(properties, data["ID"], data["Desc"], 1024, 65535, 1)
		obs.obs_property_set_long_description(prop, data["Tooltip"])
		obs.obs_property_set_modified_callback(prop, ScriptManager.criticalPropertyModified)

		# Twitch application client ID setting
		data = UIElements[Property.APIID]
		prop = obs.obs_properties_add_text(properties, data["ID"], data["Desc"], obs.OBS_TEXT_PASSWORD)
		obs.obs_property_set_long_description(prop, data["Tooltip"])

		# Server status line
		data = UIElements[Property.STATUS]
		prop = obs.obs_properties_add_text(properties, data["ID"], data["Desc"], obs.OBS_TEXT_INFO)

		# Server start/stop button
		data = UIElements[Property.CONTROL]
		prop = obs.obs_properties_add_button(properties, data["ID"], data["Desc"], ScriptManager.controlClickedCallback)
		obs.obs_property_set_long_description(prop, data["Tooltip"])

		### Dummy debugging button ###
		prop = obs.obs_properties_add_button(properties, "debug", "DEBUG", ScriptManager.debugClickedCallback)
		obs.obs_property_set_visible(prop, False)
		##############################

		# Should server automatically start checkbox
		data = UIElements[Property.RESTART]
		prop = obs.obs_properties_add_bool(properties, data["ID"], data["Desc"])
		obs.obs_property_set_long_description(prop, data["Tooltip"])

		self.properties = properties

	# Modify button and status message strings
	def updateUI(self):
		if self.properties is None:
			self.log("DEBUG NOTE: updateUI() properties not yet generated")
			return
		status = self.updateStatus()

		# Control button
		buttonStr = "Start"
		if status: buttonStr = "Stop"

		button = obs.obs_properties_get(self.properties, UIElements[Property.CONTROL]["ID"])
		if button is None: self.warn("Control button object not found!")
		else: obs.obs_property_set_description(button, buttonStr)

		# Status line
		statusStr = "STOPPED"
		if status: statusStr = "RUNNING"

		msg = obs.obs_properties_get(self.properties, UIElements[Property.STATUS]["ID"])
		if msg is None: self.warn("Status message object not found!")
		else: obs.obs_property_set_description(msg, "Server status: " + statusStr)


	# Helper function for updateServerSettings
	# settings is reference to OBS settings object
	# property is Property enum type
	# critical is whether the server should restart if the settings has changed
	def updateSetting(self, settings, property, critical = False):
		propVal = getSetting(settings, property)

		if propVal is None: return False
		if propVal == self.serverSettings[property]: return False

		self.serverSettings[property] = propVal
		return critical

	# Update interal settings with those parsed from the settings object
	def updateServerSettings(self, settings):
		# Basic settings
		self.updateSetting(settings, Property.RESTART)
		self.updateSetting(settings, Property.APIID)

		# Critical settings
		dirChanged = self.updateSetting(settings, Property.DIR, critical = True)
		portChanged = self.updateSetting(settings, Property.PORT, critical = True)

		# For debugging: Keep the reference up to date (it shouldn't change but just in case)
		# self.log("Settings ref (UPDATE): " + str(settings))

		if dirChanged or portChanged:
			self.stopServer()

	# Check the thread status and save the state
	def updateStatus(self):
		# For debugging
		# self.running = not self.running
		# return self.running

		if self.serverThread is None: 
			self.running = False

		else:
			assert type(self.serverThread) == Thread
			self.running = self.serverThread.is_alive()

		return self.running

	# -- Script operation functions --
	def startServer(self):
		self.log("Starting server...")

		if self.serverThread is not None:
			# TODO Determine what type of exception this should be
			self.warn("Attempt to start server with non-null thread!")
			return

		# Create the server
		# TODO If client secret is necessary, be sure to add it as a server data
		self.alertServer = AlertServer(
			("localhost", self.serverSettings[Property.PORT]), 
			RequestHandler, 
			self.serverSettings[Property.DIR], 
			self.serverSettings[Property.APIID])

		# Start the server thread
		self.serverThread = Thread(target = self.alertServer.serve_forever)
		self.serverThread.start()
		self.log("Server successfully started")

		self.updateUI()
	
	def stopServer(self):
		self.log("Stopping server...")

		if self.serverThread is None:
			self.log("Server already stopped")
			return

		self.alertServer.shutdown()			# Stop serve_forever loop (exits thread)
		self.serverThread.join()			# Waits for loop to finish
		self.alertServer.server_close()		# Cleans up server allocation (such as closing the port)

		# Clean up thread (thread should be None if not running)
		self.serverThread = None
		self.log("Server successfully stopped")

		self.updateUI()


class AlertServer(HTTPServer):
	def __init__(self, serverAddress, RequestHandlerClass, directory, clientID):
		super().__init__(serverAddress, RequestHandlerClass)
		self.directory = directory
		self.clientID = clientID

	# Override finish_request to generate RequestHandlerClass instance with specified directory
	def finish_request(self, request, client_address):
		self.RequestHandlerClass(request, client_address, self, directory = self.directory)


# Request handler
# TODO Deny all requests except those from localhost
class RequestHandler(SimpleHTTPRequestHandler):
	# Override server logging
	def log_message(self, format, *args):
		# TODO Consider actually logging requests (need to figure out how to give the script a name for the sake of OBS)
		# obs.script_log(obs.LOG_INFO, "%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format%args))
		pass

	# POST -> If connection is verified, update the authentication information
	#  ^^(allows for configuration via browser other than OBS)
	def do_POST(self): 
		print("this is a POST request")
	
	# GET -> Default implementationstart

# --------------------------------------------------------------------------- #

# Support testing outside of OBS
def serverTest(port):
	print("This is an HTTP server test!")
	alertServer = HTTPServer(("localhost", port), RequestHandler)

	serverThread = Thread(target = alertServer.serve_forever)
	serverThread.start()
	
	time.sleep(5)

	print("Exiting...")
	alertServer.shutdown()
	serverThread.join()

if __name__ == "__main__":
	import time
	serverTest(1085)
	exit()

# --------------------------------------------------------------------------- #
# Global reference to the script manager instance
SCRIPT = None

# Provide OBS with a script description
def script_description():
	return "Establishes a local web server for handling authenticated Twitch API requests."

# Specify the user properties for the script
def script_properties():
	# obs.script_log(obs.LOG_DEBUG, "Script properties")
	# if SCRIPT is None: return None

	# OBS will segfault if this is not called from within this function
	# Theory:
	# I *think* the script is ran "nested" within a larger Python script.
	# So when this function returns, the binding is saved within the parent
	# script, so the destruction of this script does not Null the binding,
	# causing OBS core to segfault by freeing a Null pointer
	properties = obs.obs_properties_create()

	SCRIPT.setProperties(properties)
	SCRIPT.updateUI()
	return properties

# Specify the default values for user settings within the script
def script_defaults(settings):
	# obs.script_log(obs.LOG_DEBUG, "Settings ref (DEFAULTS): " + str(settings))
	for element in UIElements:
		setSettingDefault(settings, element)

# Called each time a user setting changes (includes once during load)
# TODO figure out how to update UI
def script_update(settings):
	if SCRIPT is None: return
	# SCRIPT.printSettings(settings)
	SCRIPT.updateServerSettings(settings)

# Called when the script is loaded (or reloaded)
def script_load(settings):
	# Also totally unusure but I need this global identifier here, but nowhere else?
	global SCRIPT

	# obs.script_log(obs.LOG_DEBUG, "Settings ref (LOAD): " + str(settings))
	SCRIPT = ScriptManager(settings)

# Stop the thread if the script is unloaded
# OBS will 'leak' the thread if exited unconventionally
# Fix this with: pkill -KILL /usr/bin/obs
# Check process state: ps -aux | grep obs
def script_unload():
	if SCRIPT is None: return
	# obs.script_log(obs.LOG_INFO, "Script UNLOAD")
	SCRIPT.stopServer()
