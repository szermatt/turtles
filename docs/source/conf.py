# Configuration file for the Sphinx documentation builder.

# -- Project information

project = 'turtles'
copyright = '2024, 2025, Stephane Zermatten'
author = 'Stephane Zermatten'

release = '2.1.1snapshot'
version = '2.1.1snapshot'

# -- General configuration

extensions = [
    'sphinx.ext.duration',
    'sphinx.ext.doctest',
    'sphinx.ext.autodoc',
    'sphinx.ext.autosummary',
    'sphinx.ext.intersphinx',

    'sphinx_copybutton',
]

root_doc = "index"

intersphinx_mapping = {
    'python': ('https://docs.python.org/3/', None),
    'sphinx': ('https://www.sphinx-doc.org/en/master/', None),
}
intersphinx_disabled_domains = ['std']

templates_path = ['_templates']

# -- Options for HTML output

html_theme = 'sphinx_rtd_theme'

# -- Options for EPUB output
epub_show_urls = 'footnote'

# -- Options for Texinfo output

texinfo_documents = [
    (
        # startdocname
        root_doc,
        # targetname
        "turtles",
        # title
        "Visual Replace",
        # author
        "Stephane Zermatten",
        # dir_entry
        "turtles",
        # description
        "Library for writing ERT-based tests that check how Emacs renders buffers and windows.",
        # category
        "Emacs",
        # toctree_only
        False,
    )
]
