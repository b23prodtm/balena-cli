/**
 * @license
 * Copyright 2016-2020 Balena Ltd.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { flags } from '@oclif/command';
import { stripIndent } from 'common-tags';
import Command from '../../command';
import { ExpectedError } from '../../errors';
import * as cf from '../../utils/common-flags';
import { getBalenaSdk } from '../../utils/lazy';
import { disambiguateReleaseParam } from '../../utils/normalization';
import { tryAsInteger } from '../../utils/validation';

interface FlagsDef {
	application?: string;
	device?: string;
	release?: string;
	help: void;
	app?: string;
}

interface ArgsDef {
	tagKey: string;
	value?: string;
}

export default class TagSetCmd extends Command {
	public static description = stripIndent`
		Set a tag on an application, device or release.

		Set a tag on an application, device or release.

		You can optionally provide a value to be associated with the created
		tag, as an extra argument after the tag key. If a value isn't
		provided, a tag with an empty value is created.
	`;

	public static examples = [
		'$ balena tag set mySimpleTag --application MyApp',
		'$ balena tag set myCompositeTag myTagValue --application MyApp',
		'$ balena tag set myCompositeTag myTagValue --device 7cf02a6',
		'$ balena tag set myCompositeTag "my tag value with whitespaces" --device 7cf02a6',
		'$ balena tag set myCompositeTag myTagValue --release 1234',
		'$ balena tag set myCompositeTag --release 1234',
		'$ balena tag set myCompositeTag --release b376b0e544e9429483b656490e5b9443b4349bd6',
	];

	public static args = [
		{
			name: 'tagKey',
			description: 'the key string of the tag',
			required: true,
		},
		{
			name: 'value',
			description: 'the optional value associated with the tag',
			required: false,
		},
	];

	public static usage = 'tag set <tagKey> [value]';

	public static flags: flags.Input<FlagsDef> = {
		application: {
			...cf.application,
			exclusive: ['app', 'device', 'release'],
		},
		device: {
			...cf.device,
			exclusive: ['app', 'application', 'release'],
		},
		release: {
			...cf.release,
			exclusive: ['app', 'application', 'device'],
		},
		help: cf.help,
		app: flags.string({
			description: "same as '--application'",
			exclusive: ['application', 'device', 'release'],
		}),
	};

	public static authenticated = true;

	public async run() {
		const { args: params, flags: options } = this.parse<FlagsDef, ArgsDef>(
			TagSetCmd,
		);

		// Prefer options.application over options.app
		options.application = options.application || options.app;
		delete options.app;

		const balena = getBalenaSdk();

		// Check user has specified one of application/device/release
		if (!options.application && !options.device && !options.release) {
			throw new ExpectedError(TagSetCmd.missingResourceMessage);
		}

		if (params.value == null) {
			params.value = '';
		}

		if (options.application) {
			return balena.models.application.tags.set(
				tryAsInteger(options.application),
				params.tagKey,
				params.value,
			);
		}
		if (options.device) {
			return balena.models.device.tags.set(
				tryAsInteger(options.device),
				params.tagKey,
				params.value,
			);
		}
		if (options.release) {
			const releaseParam = await disambiguateReleaseParam(
				balena,
				options.release,
			);

			return balena.models.release.tags.set(
				releaseParam,
				params.tagKey,
				params.value,
			);
		}
	}

	protected static missingResourceMessage = stripIndent`
					To set a resource tag, you must provide exactly one of:

					  * An application, with --application <appname>
					  * A device, with --device <uuid>
					  * A release, with --release <id or commit>

					See the help page for examples:

					  $ balena help tag set
	`;
}
