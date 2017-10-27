###
Copyright 2016-2017 Resin.io

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
###

dockerUtils = require('../utils/docker')

LATEST = 'latest'

getApplicationsWithSuccessfulBuilds = (deviceType) ->
	preload = require('resin-preload')
	resin = require('resin-sdk-preconfigured')

	resin.pine.get
		resource: 'my_application'
		options:
			filter:
				device_type: deviceType
				build:
					$any:
						$alias: 'b'
						$expr:
							b:
								status: 'success'
			expand: preload.applicationExpandOptions
			select: [ 'id', 'app_name', 'device_type', 'commit' ]
			orderby: 'app_name asc'

selectApplication = (deviceType) ->
	visuals = require('resin-cli-visuals')
	form = require('resin-cli-form')
	{ expectedError } = require('../utils/patterns')

	applicationInfoSpinner = new visuals.Spinner('Downloading list of applications and builds.')
	applicationInfoSpinner.start()

	getApplicationsWithSuccessfulBuilds(deviceType)
	.then (applications) ->
		applicationInfoSpinner.stop()
		if applications.length == 0
			expectedError("You have no apps with successful builds for a '#{deviceType}' device type.")
		form.ask
			message: 'Select an application'
			type: 'list'
			choices: applications.map (app) ->
				name: app.app_name
				value: app

selectApplicationCommit = (builds) ->
	form = require('resin-cli-form')
	{ expectedError } = require('../utils/patterns')

	if builds.length == 0
		expectedError('This application has no successful builds.')
	DEFAULT_CHOICE = {'name': LATEST, 'value': LATEST}
	choices = [ DEFAULT_CHOICE ].concat builds.map (build) ->
		name: "#{build.push_timestamp} - #{build.commit_hash}"
		value: build.commit_hash
	return form.ask
		message: 'Select a build'
		type: 'list'
		default: LATEST
		choices: choices

offerToDisableAutomaticUpdates = (application, commit) ->
	Promise = require('bluebird')
	resin = require('resin-sdk-preconfigured')
	form = require('resin-cli-form')

	if commit == LATEST or not application.should_track_latest_release
		return Promise.resolve()
	message = '''

		This application is set to automatically update all devices to the latest available version.
		This might be unexpected behaviour: with this enabled, the preloaded device will still
		download and install the latest build once it is online.

		Do you want to disable automatic updates for this application?
	'''
	form.ask
		message: message,
		type: 'confirm'
	.then (update) ->
		if not update
			return
		resin.pine.patch
			resource: 'application'
			id: application.id
			body:
				should_track_latest_release: false

module.exports =
	signature: 'preload <image>'
	description: '(beta) preload an app on a disk image (or Edison zip archive)'
	help: '''
		Warning: "resin preload" requires Docker to be correctly installed in
		your shell environment. For more information (including Windows support)
		please check the README here: https://github.com/resin-io/resin-cli .

		Use this command to preload an application to a local disk image (or
		Edison zip archive) with a built commit from Resin.io.
		This can be used with cloud builds, or images deployed with resin deploy.

		Examples:
		  $ resin preload resin.img --app 1234 --commit e1f2592fc6ee949e68756d4f4a48e49bff8d72a0 --splash-image some-image.png
		  $ resin preload resin.img
	'''
	permission: 'user'
	primary: true
	options: dockerUtils.appendConnectionOptions [
		{
			signature: 'app'
			parameter: 'appId'
			description: 'id of the application to preload'
			alias: 'a'
		}
		{
			signature: 'commit'
			parameter: 'hash'
			description: '''
				a specific application commit to preload, use "latest" to specify the latest commit
				(ignored if no appId is given)
			'''
			alias: 'c'
		}
		{
			signature: 'splash-image'
			parameter: 'splashImage.png'
			description: 'path to a png image to replace the splash screen'
			alias: 's'
		}
		{
			signature: 'dont-check-device-type'
			boolean: true
			description: 'Disables check for matching device types in image and application'
		}
	]
	action: (params, options, done) ->
		_ = require('lodash')
		Promise = require('bluebird')
		resin = require('resin-sdk-preconfigured')
		streamToPromise = require('stream-to-promise')
		form = require('resin-cli-form')
		preload = require('resin-preload')
		errors = require('resin-errors')
		visuals = require('resin-cli-visuals')
		nodeCleanup = require('node-cleanup')
		{ expectedError } = require('../utils/patterns')

		progressBars = {}

		progressHandler = (event) ->
			progressBar = progressBars[event.name]
			if not progressBar
				progressBar = progressBars[event.name] = new visuals.Progress(event.name)
			progressBar.update(percentage: event.percentage)

		spinners = {}

		spinnerHandler = (event) ->
			spinner = spinners[event.name]
			if not spinner
				spinner = spinners[event.name] = new visuals.Spinner(event.name)
			if event.action == 'start'
				spinner.start()
			else
				console.log()
				spinner.stop()

		options.image = params.image
		options.appId = options.app
		delete options.app

		options.splashImage = options['splash-image']
		delete options['splash-image']

		if options['dont-check-device-type'] and not options.appId
			expectedError('You need to specify an app id if you disable the device type check.')

		# Get a configured dockerode instance
		dockerUtils.getDocker(options)
		.then (docker) ->

			preloader = new preload.Preloader(
				resin,
				docker,
				options.appId,
				options.commit,
				options.image,
				options.splashImage,
				options.proxy,
			)

			gotSignal = false

			nodeCleanup (exitCode, signal) ->
				if signal
					gotSignal = true
					nodeCleanup.uninstall()  # don't call cleanup handler again
					preloader.cleanup()
					.then ->
						# calling process.exit() won't inform parent process of signal
						process.kill(process.pid, signal)
					return false

			if process.env.DEBUG
				preloader.stderr.pipe(process.stderr)

			preloader.on('progress', progressHandler)
			preloader.on('spinner', spinnerHandler)

			return new Promise (resolve, reject) ->
				preloader.on('error', reject)

				preloader.build()
				.then ->
					preloader.prepare()
				.then ->
					preloader.getDeviceTypeAndPreloadedBuilds()
				.then (info) ->
					Promise.try ->
						if options.appId
							return preloader.fetchApplication()
							.catch(errors.ResinApplicationNotFound, expectedError)
						selectApplication(info.device_type)
					.then (application) ->
						preloader.setApplication(application)
						# Check that the app device type and the image device type match
						if not options['dont-check-device-type'] and info.device_type != application.device_type
							expectedError(
								"Image device type (#{info.device_type}) and application device type (#{application.device_type}) do not match"
							)

						# Use the commit given as --commit or show an interactive commit selection menu
						Promise.try ->
							if options.commit
								if options.commit == LATEST and application.commit
									# handle `--commit latest`
									return LATEST
								else if not _.find(application.build, commit_hash: options.commit)
									expectedError('There is no build matching this commit')
								return options.commit
							selectApplicationCommit(application.build)
						.then (commit) ->
							if commit == LATEST
								preloader.commit = application.commit
							else
								preloader.commit = commit

							# Propose to disable automatic app updates if the commit is not the latest
							offerToDisableAutomaticUpdates(application, commit)
					.then ->
						builds = info.preloaded_builds.map (build) ->
							build.slice(-preload.BUILD_HASH_LENGTH)
						if preloader.commit in builds
							throw new preload.errors.ResinError('This build is already preloaded in this image.')
						# All options are ready: preload the image.
						preloader.preload()
						.catch(preload.errors.ResinError, expectedError)
				.then(resolve)
				.catch(reject)
			.then(done)
			.finally ->
				if not gotSignal
					preloader.cleanup()
