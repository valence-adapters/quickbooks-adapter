/**
 * Helps configure the Valence Quickbooks Adapter.
 */

import ValenceUIConfigurator from 'c/valenceUIConfigurator';

export default class QuickbooksAdapterTargetConfigurator extends ValenceUIConfigurator {

	// ------------------------------------------
	// ----- Configurator Lifecycle Methods -----
	// ------------------------------------------

	// -------------------------------------------
	// ----- User Manipulating Configuration -----
	// -------------------------------------------

	addMainPair() {
		this.configuration.mainPairs.push({'qbo' : '<field>', 'sf' : null});
		this.configUpdated(); // propagate our configuration changes
	}

	removeMainPair(event) {
		this.configuration.mainPairs.splice(event.target.value, 1);
		this.configUpdated(); // propagate our configuration changes
	}

	addListSection() {
		this.configuration.listPairs.push({'qboListFieldName' : null, 'sfListFieldName' : null, 'sfObjectName' : null, pairs : []});
		this.configUpdated(); // propagate our configuration changes
	}

	removeListSection(event) {
		this.configuration.listPairs.splice(event.target.value, 1);
		this.configUpdated(); // propagate our configuration changes
	}

	addListPair(event) {
		this.configuration.listPairs[event.target.value].pairs.push({'qbo' : '<field>', 'sf' : null});
		this.configUpdated(); // propagate our configuration changes
	}

	removeListPair(event) {
		this.configuration.listPairs[event.target.dataset.sectionIndex].pairs.splice(event.target.value, 1);
		this.configUpdated(); // propagate our configuration changes
	}

	longDebounceMetaUpdate(event) {
		// we debounce so that the user isn't forced to click out of the field before they click save changes, but we use a long debounce so the field doesn't lose focus on re-render
		const section = event.target.dataset.sectionIndex, name = event.target.name, value = event.target.value;
		this.debounce(() => {
				this.configuration.listPairs[section][name] = value;
			}, 2000
		);
		this.configUpdated(); // propagate our configuration changes
	}

	updateMetaImmediately(event) {
		clearTimeout(this._debounceTimer); // cancel any pending debounce
		this.configuration.listPairs[event.target.dataset.sectionIndex][event.target.name] = event.target.value;
		this.configUpdated(); // propagate our configuration changes
	}

	longDebouncePairUpdate(event) {
		// we debounce so that the user isn't forced to click out of the field before they click save changes, but we use a long debounce so the field doesn't lose focus on re-render
		const index = event.target.dataset.index, section = event.target.dataset.sectionIndex, name = event.target.name, value = event.target.value;
		this.debounce(() => {
				this.updatePair(index, section, name, value);
			}, 2000
		);
	}

	updatePairImmediately(event) {
		clearTimeout(this._debounceTimer); // cancel any pending debounce
		this.updatePair(event.target.dataset.index, event.target.dataset.sectionIndex, event.target.name, event.target.value);
	}

	updatePair(index, section, name, value) {
		if(section) { // modification to a nested list pair
			this.configuration.listPairs[section].pairs[index][name] = value;
		} else {
			this.configuration.mainPairs[index][name] = value;
		}
		this.configUpdated(); // propagate our configuration changes
	}

	// -----------------------------------------
	// ----- Required Configurator Methods -----
	// -----------------------------------------

	getDefaultShape() {
		return {mainPairs : [], listPairs : []};
	}

	computeValid() {
		// check that we have values in every one of our input fields
		return this.configuration.mainPairs.every(pair => pair.qbo && pair.sf) &&
			this.configuration.listPairs.every(pair =>
				pair.qboListFieldName && pair.sfListFieldName && pair.sfObjectName && pair.pairs.every(listPair => listPair.qbo && listPair.sf)
			);
	}
}